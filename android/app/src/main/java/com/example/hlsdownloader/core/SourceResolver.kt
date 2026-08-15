package com.example.hlsdownloader.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import okhttp3.HttpUrl
import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

class SourceResolver(
    private val client: HlsHttpClient,
    private val dynamicInspector: DynamicPageInspector? = null,
    private val diagnosticSink: DiagnosticSink? = null,
    private val maximumHtmlBytes: Int = 8 * 1024 * 1024,
    private val maximumDocuments: Int = 16,
    private val maximumIframeDepth: Int = 3,
    private val maximumFramesPerDocument: Int = 12,
    private val maximumCandidateReferences: Int = 128,
    private val maximumResults: Int = 64,
) {
    private sealed interface DocumentSource {
        data class Loaded(val html: String, val url: HttpUrl) : DocumentSource
        data class Remote(val url: HttpUrl) : DocumentSource
    }

    private data class DocumentWork(
        val source: DocumentSource,
        val referer: HttpUrl?,
        val iframeDepth: Int,
        val inheritedTitle: String?,
        val inheritedThumbnailUrl: HttpUrl?,
    )

    suspend fun discover(input: String): HlsDiscoveryResult {
        val inputUrl = UriResolver.normalizeInput(input)
        log("discovery", "start ${DiagnosticPrivacy.urlSummary(inputUrl)}")
        val payload = try {
            client.fetch(inputUrl, maximumBytes = maximumHtmlBytes + 1)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log("network", "root failed error=${DiagnosticPrivacy.errorCode(error)}; trying WebView fallback")
            val candidates = dynamicallyDiscoveredCandidates(inputUrl)
            if (candidates.isNotEmpty()) return HlsDiscoveryResult(candidates, false)
            throw error
        }
        log(
            "network",
            "root response status=${payload.statusCode} mime=${DiagnosticPrivacy.mimeClass(payload.mimeType)} " +
                "bytes=${payload.data.size} redirected=${payload.effectiveUrl != inputUrl} " +
                DiagnosticPrivacy.urlSummary(payload.effectiveUrl),
        )
        if (!AutomaticNavigationPolicy.isAllowedFrameNavigation(inputUrl, payload.effectiveUrl)) {
            throw HlsException.Network("公開URLからローカルネットワークへのリダイレクトを拒否しました")
        }
        val text = decodeText(payload.data) ?: run {
            val candidates = dynamicallyDiscoveredCandidates(payload.effectiveUrl)
            if (candidates.isEmpty()) throw HlsException.NoPlaylistFound()
            return HlsDiscoveryResult(candidates, false)
        }

        if (PlaylistParser.isPlaylist(text)) {
            val document = PlaylistDocument(text, payload.effectiveUrl, inputUrl)
            return HlsDiscoveryResult(
                candidates = listOf(
                    HlsCandidate(
                        request = UrlCandidates(payload.effectiveUrl),
                        requestReferer = inputUrl,
                        document = document,
                        pageUrl = payload.effectiveUrl,
                        title = null,
                        thumbnailUrl = null,
                        iframeDepth = 0,
                        origin = HlsCandidateOrigin.DIRECT,
                    ),
                ),
                isDirectPlaylist = true,
            )
        }
        if (payload.data.size > maximumHtmlBytes) {
            val candidates = dynamicallyDiscoveredCandidates(payload.effectiveUrl)
            if (candidates.isEmpty()) throw HlsException.HtmlTooLarge()
            return HlsDiscoveryResult(candidates, false)
        }
        val candidates = discoverInHtml(text, payload.effectiveUrl, inputUrl)
        if (candidates.isEmpty()) throw HlsException.NoPlaylistFound()
        return HlsDiscoveryResult(candidates, false)
    }

    suspend fun resolve(input: String): PlaylistDocument {
        val candidate = discover(input).candidates.firstOrNull() ?: throw HlsException.NoPlaylistFound()
        return candidate.document ?: load(candidate.request, candidate.requestReferer)
    }

    fun importDynamicInspection(
        inspection: DynamicPageInspection,
        rootUrl: HttpUrl,
    ): List<HlsCandidate> {
        client.storeCookies(inspection.cookies)
        val discovered = mutableSetOf<String>()
        val results = mutableListOf<HlsCandidate>()
        appendDynamicCandidates(inspection, rootUrl, discovered, results)
        log(
            "playback",
            "interactive inspection imported references=${inspection.media.size} " +
                "candidates=${results.size} cookies=${inspection.cookies.size}",
        )
        return results
    }

    suspend fun load(candidates: UrlCandidates, referer: HttpUrl?): PlaylistDocument {
        var lastError: Throwable = HlsException.InvalidPlaylist("リンク先がm3u8ではありません")
        candidates.all.forEach { candidate ->
            try {
                val payload = client.fetch(candidate, referer, maximumBytes = 4 * 1024 * 1024)
                val text = decodeText(payload.data)
                if (text == null || !PlaylistParser.isPlaylist(text)) {
                    throw HlsException.InvalidPlaylist("リンク先がm3u8ではありません")
                }
                return PlaylistDocument(text, payload.effectiveUrl, referer)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (error is HlsException.Cancelled) throw error
                lastError = error
                log("playlist", "candidate rejected error=${DiagnosticPrivacy.errorCode(error)}")
            }
        }
        throw lastError
    }

    private suspend fun discoverInHtml(
        rootHtml: String,
        rootUrl: HttpUrl,
        rootReferer: HttpUrl?,
    ): List<HlsCandidate> = coroutineScope {
        val dynamicDeferred = async { inspectDynamically(rootUrl) }
        val queue = mutableListOf(
            DocumentWork(DocumentSource.Loaded(rootHtml, rootUrl), rootReferer, 0, null, null),
        )
        var queueIndex = 0
        var processedDocuments = 0
        val visitedRemoteDocuments = mutableSetOf(canonicalUrlKey(rootUrl))
        val discovered = mutableSetOf<String>()
        val results = mutableListOf<HlsCandidate>()

        while (
            queueIndex < queue.size && processedDocuments < maximumDocuments && results.size < maximumResults
        ) {
            val work = queue[queueIndex++]
            val html: String
            val documentUrl: HttpUrl
            when (val source = work.source) {
                is DocumentSource.Loaded -> {
                    processedDocuments += 1
                    html = source.html
                    documentUrl = source.url
                }
                is DocumentSource.Remote -> {
                    val requestedKey = canonicalUrlKey(source.url)
                    if (!visitedRemoteDocuments.add(requestedKey)) continue
                    processedDocuments += 1
                    val payload = try {
                        client.fetch(
                            source.url,
                            referer = work.referer,
                            maximumBytes = maximumHtmlBytes + 1,
                            redirectPolicy = { _, target ->
                                AutomaticNavigationPolicy.isAllowedNativeFrameNavigation(rootUrl, target)
                            },
                        )
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Throwable) {
                        log("iframe", "fetch failed error=${DiagnosticPrivacy.errorCode(error)}")
                        continue
                    }
                    if (!AutomaticNavigationPolicy.isAllowedNativeFrameNavigation(rootUrl, payload.effectiveUrl)) {
                        log("iframe", "blocked by navigation policy depth=${work.iframeDepth}")
                        continue
                    }
                    val effectiveKey = canonicalUrlKey(payload.effectiveUrl)
                    if (effectiveKey != requestedKey && !visitedRemoteDocuments.add(effectiveKey)) continue
                    val fetchedText = decodeText(payload.data) ?: continue
                    if (PlaylistParser.isPlaylist(fetchedText)) {
                        addOrMergeCandidate(
                            HlsCandidate(
                                request = UrlCandidates(payload.effectiveUrl),
                                requestReferer = work.referer,
                                document = PlaylistDocument(fetchedText, payload.effectiveUrl, work.referer),
                                pageUrl = work.referer ?: payload.effectiveUrl,
                                title = work.inheritedTitle,
                                thumbnailUrl = work.inheritedThumbnailUrl,
                                iframeDepth = work.iframeDepth,
                                origin = HlsCandidateOrigin.IFRAME,
                            ),
                            results,
                        )
                        continue
                    }
                    if (payload.data.size > maximumHtmlBytes) continue
                    html = fetchedText
                    documentUrl = payload.effectiveUrl
                }
            }

            val extraction = HtmlMediaExtractor.extract(html)
            val documentBaseUrl = resolvedAutomaticUrl(extraction.baseHref, documentUrl)
                ?.takeIf { AutomaticNavigationPolicy.isAllowedFrameNavigation(rootUrl, it) }
                ?: documentUrl
            val pageTitle = limitedTitle(extraction.title ?: work.inheritedTitle)
            val resolvedPageThumbnail = resolvedAutomaticUrl(
                extraction.rawThumbnailUrl,
                documentBaseUrl,
            ) ?: work.inheritedThumbnailUrl
            val pageThumbnail = resolvedPageThumbnail?.takeIf {
                AutomaticNavigationPolicy.isAllowedFrameNavigation(rootUrl, it)
            }

            extraction.media.forEach { reference ->
                if (results.size >= maximumResults || discovered.size >= maximumCandidateReferences) return@forEach
                val request = try {
                    UriResolver.resolve(reference.rawUrl, documentBaseUrl, documentUrl)
                } catch (_: HlsException) {
                    return@forEach
                }
                if (
                    !isSafeAutomaticUrl(request.primary) ||
                    !AutomaticNavigationPolicy.isAllowedFrameNavigation(rootUrl, request.primary)
                ) return@forEach
                discovered += candidateKey(request.primary, documentUrl)
                val thumbnail = (resolvedAutomaticUrl(reference.rawPosterUrl, documentBaseUrl) ?: pageThumbnail)
                    ?.takeIf { AutomaticNavigationPolicy.isAllowedFrameNavigation(rootUrl, it) }
                addOrMergeCandidate(
                    HlsCandidate(
                        request = request,
                        requestReferer = documentUrl,
                        document = null,
                        pageUrl = documentUrl,
                        title = limitedTitle(reference.title ?: pageTitle),
                        thumbnailUrl = thumbnail,
                        iframeDepth = work.iframeDepth,
                        origin = reference.origin,
                    ),
                    results,
                )
            }

            if (work.iframeDepth >= maximumIframeDepth) continue
            extraction.frames.take(maximumFramesPerDocument).forEach { frame ->
                val title = limitedTitle(frame.title ?: pageTitle)
                if (frame.sourceDocument != null) {
                    queue += DocumentWork(
                        DocumentSource.Loaded(frame.sourceDocument, documentBaseUrl),
                        documentUrl,
                        work.iframeDepth + 1,
                        title,
                        pageThumbnail,
                    )
                } else {
                    val frameUrl = resolvedAutomaticUrl(frame.rawUrl, documentBaseUrl) ?: return@forEach
                    if (AutomaticNavigationPolicy.isAllowedNativeFrameNavigation(rootUrl, frameUrl)) {
                        queue += DocumentWork(
                            DocumentSource.Remote(frameUrl),
                            documentUrl,
                            work.iframeDepth + 1,
                            title,
                            pageThumbnail,
                        )
                    }
                }
            }
        }

        val dynamic = dynamicDeferred.await()
        client.storeCookies(dynamic.cookies)
        appendDynamicCandidates(dynamic, rootUrl, discovered, results)
        results
    }

    private suspend fun inspectDynamically(url: HttpUrl): DynamicPageInspection {
        val inspector = dynamicInspector ?: return DynamicPageInspection.EMPTY
        return try {
            inspector.inspect(url, client.cookiesFor(url))
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log("webkit", "inspection failed error=${DiagnosticPrivacy.errorCode(error)}")
            DynamicPageInspection.EMPTY
        }
    }

    private suspend fun dynamicallyDiscoveredCandidates(rootUrl: HttpUrl): List<HlsCandidate> {
        val dynamic = inspectDynamically(rootUrl)
        return importDynamicInspection(dynamic, rootUrl)
    }

    private fun appendDynamicCandidates(
        inspection: DynamicPageInspection,
        rootUrl: HttpUrl,
        discovered: MutableSet<String>,
        results: MutableList<HlsCandidate>,
    ) {
        inspection.media.forEach { reference ->
            if (results.size >= maximumResults || discovered.size >= maximumCandidateReferences) return@forEach
            if (
                !isSafeAutomaticUrl(reference.url) ||
                !AutomaticNavigationPolicy.isAllowedFrameNavigation(rootUrl, reference.url)
            ) return@forEach
            val pageUrl = reference.pageUrl.takeIf {
                isSafeAutomaticUrl(it) && AutomaticNavigationPolicy.isAllowedFrameNavigation(rootUrl, it)
            } ?: rootUrl
            val requestReferer = reference.requestReferer?.takeIf {
                isSafeAutomaticUrl(it) && AutomaticNavigationPolicy.isAllowedFrameNavigation(rootUrl, it)
            } ?: pageUrl
            discovered += candidateKey(reference.url, requestReferer)
            addOrMergeCandidate(
                HlsCandidate(
                    request = UrlCandidates(reference.url),
                    requestReferer = requestReferer,
                    document = null,
                    pageUrl = pageUrl,
                    title = limitedTitle(reference.title),
                    thumbnailUrl = reference.thumbnailUrl?.takeIf {
                        isSafeAutomaticUrl(it) &&
                            AutomaticNavigationPolicy.isAllowedFrameNavigation(rootUrl, it)
                    },
                    iframeDepth = reference.iframeDepth.coerceAtLeast(0),
                    origin = reference.origin,
                ),
                results,
            )
        }
    }

    private fun addOrMergeCandidate(candidate: HlsCandidate, results: MutableList<HlsCandidate>) {
        val key = candidateKey(
            candidate.document?.effectiveUrl ?: candidate.request.primary,
            candidate.document?.referer ?: candidate.requestReferer ?: candidate.pageUrl,
        )
        val index = results.indexOfFirst {
            candidateKey(
                it.document?.effectiveUrl ?: it.request.primary,
                it.document?.referer ?: it.requestReferer ?: it.pageUrl,
            ) == key
        }
        if (index < 0) {
            results += candidate
            return
        }
        val existing = results[index]
        results[index] = existing.copy(
            request = if (existing.request.sameOriginQueryFallback != null) existing.request else candidate.request,
            requestReferer = existing.requestReferer ?: candidate.requestReferer,
            document = existing.document ?: candidate.document,
            title = existing.title ?: candidate.title,
            thumbnailUrl = existing.thumbnailUrl ?: candidate.thumbnailUrl,
            iframeDepth = minOf(existing.iframeDepth, candidate.iframeDepth),
        )
    }

    private fun resolvedAutomaticUrl(raw: String?, baseUrl: HttpUrl): HttpUrl? {
        if (raw == null) return null
        val url = try {
            UriResolver.resolveUrl(raw, baseUrl)
        } catch (_: HlsException) {
            return null
        }
        return url.takeIf(::isSafeAutomaticUrl)?.newBuilder()?.fragment(null)?.build()
    }

    private fun isSafeAutomaticUrl(url: HttpUrl): Boolean =
        (url.scheme == "http" || url.scheme == "https") &&
            url.host.isNotEmpty() && url.username.isEmpty() && url.password.isEmpty()

    private fun canonicalUrlKey(url: HttpUrl): String = url.newBuilder().fragment(null).build().toString()

    private fun candidateKey(url: HttpUrl, referer: HttpUrl?): String =
        canonicalUrlKey(url) + "\n" + (referer?.let(::canonicalUrlKey) ?: "")

    private fun limitedTitle(title: String?): String? = title?.trim()?.takeIf(String::isNotEmpty)?.take(160)

    private fun decodeText(data: ByteArray): String? = try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(data))
            .toString()
    } catch (_: Throwable) {
        try {
            data.toString(Charset.forName("ISO-8859-1"))
        } catch (_: Throwable) {
            null
        }
    }

    private fun log(category: String, message: String) {
        diagnosticSink?.invoke(DiagnosticEvent(category, message))
    }
}
