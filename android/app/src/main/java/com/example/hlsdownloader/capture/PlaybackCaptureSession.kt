package com.example.hlsdownloader.capture

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Message
import android.os.Looper
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.ScriptHandler
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.example.hlsdownloader.core.DiagnosticPrivacy
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.Cookie
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

enum class CaptureOrigin {
    VIDEO,
    SOURCE,
    INLINE_SCRIPT,
    IFRAME,
    RUNTIME,
}

data class CapturedMediaReference(
    val url: HttpUrl,
    val pageUrl: HttpUrl,
    val requestReferer: HttpUrl?,
    val title: String?,
    val thumbnailUrl: HttpUrl?,
    val iframeDepth: Int,
    val origin: CaptureOrigin,
)

data class PlaybackCaptureSnapshot(
    val media: List<CapturedMediaReference>,
    val cookies: List<Cookie>,
)

data class PlaybackCaptureState(
    val currentUrl: HttpUrl?,
    val canGoBack: Boolean,
    val canGoForward: Boolean,
    val detectedCount: Int,
    val isLoading: Boolean,
    val isStopping: Boolean,
    val changeSequence: Long,
)

/**
 * A user-driven, visible WebView session. JavaScript discovery is treated as
 * untrusted input: every URL is parsed, bounded and checked again in Kotlin.
 */
class PlaybackCaptureSession private constructor(
    context: Context,
    val rootUrl: HttpUrl,
    private val seedCookies: List<Cookie>,
    private val interactive: Boolean,
    private val diagnosticSink: (category: String, message: String) -> Unit,
) {
    companion object {
        private const val MAXIMUM_REFERENCES = 512
        private const val MAXIMUM_RAW_MESSAGES = 4_096
        private const val MAXIMUM_URL_LENGTH = 8_192
        private const val MAXIMUM_LOGGED_REFERENCES = 64
        private const val BRIDGE_NAME = "HlsDiscoveryBridge"

        suspend fun create(
            context: Context,
            rootUrl: HttpUrl,
            seedCookies: List<Cookie> = emptyList(),
            interactive: Boolean = true,
            diagnosticSink: (category: String, message: String) -> Unit = { _, _ -> },
        ): PlaybackCaptureSession = withContext(Dispatchers.Main.immediate) {
            require(rootUrl.isSafeWebUrl()) { "Only HTTP(S) URLs without userinfo are supported" }
            PlaybackCaptureSession(
                context = context,
                rootUrl = rootUrl,
                seedCookies = seedCookies,
                interactive = interactive,
                diagnosticSink = diagnosticSink,
            )
        }
    }

    private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val bridge = DiscoveryBridge()
    private val references = LinkedHashMap<String, CapturedMediaReference>()
    private val knownCookieUrls = linkedSetOf(rootUrl)
    private val firstNavigationFinished = CompletableDeferred<Unit>()
    private val stopped = AtomicBoolean(false)
    private var documentStartScript: ScriptHandler? = null
    private var rawMessageCount = 0
    private var invalidMessageCount = 0
    private var duplicateCount = 0
    private var blockedNavigationCount = 0
    private var blockedReferenceCount = 0
    private var loggedReferenceCount = 0

    private val _state = MutableStateFlow(
        PlaybackCaptureState(
            currentUrl = rootUrl,
            canGoBack = false,
            canGoForward = false,
            detectedCount = 0,
            isLoading = false,
            isStopping = false,
            changeSequence = 0,
        ),
    )
    val state: StateFlow<PlaybackCaptureState> = _state.asStateFlow()

    val webView: WebView = WebView(context).also(::configureWebView)

    @SuppressLint("SetJavaScriptEnabled")
    private fun configureWebView(view: WebView) {
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            loadsImagesAutomatically = true
            mediaPlaybackRequiresUserGesture = interactive
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(true)
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            userAgentString = "$userAgentString HLSDownloader/1.0"
        }
        view.addJavascriptInterface(bridge, BRIDGE_NAME)
        view.webViewClient = CaptureWebViewClient()
        view.webChromeClient = CaptureChromeClient()
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(view, true)
        }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            documentStartScript = WebViewCompat.addDocumentStartJavaScript(
                view,
                DiscoveryScript.source(interactive),
                setOf("*"),
            )
            log("document-start probe enabled for all frames")
        } else {
            log("document-start unsupported; using page callback injection")
        }
    }

    suspend fun start() = withContext(Dispatchers.Main.immediate) {
        check(!stopped.get()) { "Capture session has already stopped" }
        seedCookies.forEach { cookie ->
            CookieManager.getInstance().setCookie(rootUrl.toString(), cookie.toString())
        }
        CookieManager.getInstance().flush()
        log("capture start seedCookies=${seedCookies.size} ${DiagnosticPrivacy.urlSummary(rootUrl)}")
        webView.loadUrl(rootUrl.toString())
    }

    fun goBack() {
        mainScope.launch {
            if (!stopped.get() && webView.canGoBack()) webView.goBack()
            updateNavigationState()
        }
    }

    fun goForward() {
        mainScope.launch {
            if (!stopped.get() && webView.canGoForward()) webView.goForward()
            updateNavigationState()
        }
    }

    fun reload() {
        mainScope.launch {
            if (!stopped.get()) webView.reload()
        }
    }

    /** Used by the non-visible HTML fallback inspector. */
    suspend fun awaitSettled(settleMillis: Long = 6_000, hardTimeoutMillis: Long = 20_000) {
        withTimeoutOrNull(hardTimeoutMillis) {
            firstNavigationFinished.await()
            var observedSequence: Long
            do {
                observedSequence = state.value.changeSequence
                delay(settleMillis)
            } while (state.value.changeSequence != observedSequence)
        }
    }

    suspend fun snapshotAndStop(): PlaybackCaptureSnapshot = withContext(Dispatchers.Main.immediate) {
        if (!stopped.compareAndSet(false, true)) {
            return@withContext PlaybackCaptureSnapshot(references.values.toList(), collectCookies())
        }
        _state.value = _state.value.copy(isStopping = true)
        webView.stopLoading()
        val cookies = collectCookies()
        log(
            "capture finish rawMessages=$rawMessageCount invalid=$invalidMessageCount " +
                "duplicates=$duplicateCount accepted=${references.size} " +
                "blockedNavigations=$blockedNavigationCount blockedReferences=$blockedReferenceCount " +
                "cookies=${cookies.size}",
        )
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            documentStartScript?.remove()
        }
        documentStartScript = null
        webView.removeJavascriptInterface(BRIDGE_NAME)
        webView.webChromeClient = null
        webView.webViewClient = WebViewClient()
        mainScope.cancel()
        PlaybackCaptureSnapshot(references.values.toList(), cookies)
    }

    /** Called after Compose/AndroidView has released the visible WebView. */
    fun dispose() {
        val destroy = Runnable {
            (webView.parent as? ViewGroup)?.removeView(webView)
            webView.destroy()
        }
        if (Looper.myLooper() == Looper.getMainLooper()) destroy.run() else webView.post(destroy)
    }

    private fun collectCookies(): List<Cookie> {
        val manager = CookieManager.getInstance()
        val cookies = LinkedHashMap<String, Cookie>()
        knownCookieUrls.forEach { url ->
            manager.getCookie(url.toString())
                ?.split(';')
                ?.map(String::trim)
                ?.filter(String::isNotEmpty)
                ?.forEach { pair ->
                    val separator = pair.indexOf('=')
                    if (separator <= 0) return@forEach
                    val name = pair.substring(0, separator).trim()
                    val value = pair.substring(separator + 1).trim()
                    runCatching {
                        Cookie.Builder()
                            .name(name)
                            .value(value)
                            .hostOnlyDomain(url.host)
                            .path("/")
                            .apply { if (url.isHttps) secure() }
                            .build()
                    }.getOrNull()?.let { cookie ->
                        cookies["${cookie.domain}\n${cookie.path}\n${cookie.name}"] = cookie
                    }
                }
        }
        return cookies.values.toList()
    }

    private inner class DiscoveryBridge {
        @JavascriptInterface
        fun postMessage(rawMessage: String?) {
            if (rawMessage == null || rawMessage.length > 32_768 || stopped.get()) return
            mainScope.launch { receive(rawMessage) }
        }
    }

    private fun receive(rawMessage: String) {
        if (rawMessageCount >= MAXIMUM_RAW_MESSAGES) return
        rawMessageCount += 1
        val payload = runCatching { JSONObject(rawMessage) }.getOrNull()
        if (payload == null) {
            invalidMessageCount += 1
            return
        }
        val rawUrl = payload.optString("url")
        val rawPageUrl = payload.optString("page")
        if (rawUrl.isBlank() || rawUrl.length > MAXIMUM_URL_LENGTH || rawPageUrl.length > MAXIMUM_URL_LENGTH) {
            invalidMessageCount += 1
            return
        }
        val pageUrl = rawPageUrl.toHttpUrlOrNull()?.takeIf(HttpUrl::isSafeWebUrl)
        val targetUrl = pageUrl?.resolve(rawUrl)?.takeIf(HttpUrl::isSafeWebUrl)
        if (
            pageUrl == null || targetUrl == null ||
            !NavigationSafety.isAllowed(rootUrl, pageUrl) ||
            !NavigationSafety.isAllowed(rootUrl, targetUrl)
        ) {
            blockedReferenceCount += 1
            return
        }
        val requestReferer = payload.optString("referrer")
            .takeIf { it.isNotBlank() && it.length <= MAXIMUM_URL_LENGTH }
            ?.let(pageUrl::resolve)
            ?.takeIf(HttpUrl::isSafeWebUrl)
            ?.takeIf { NavigationSafety.isAllowed(rootUrl, it) }
        val thumbnailUrl = payload.optString("poster")
            .takeIf { it.isNotBlank() && it.length <= MAXIMUM_URL_LENGTH }
            ?.let(pageUrl::resolve)
            ?.takeIf(HttpUrl::isSafeWebUrl)
            ?.takeIf { NavigationSafety.isAllowed(rootUrl, it) }
        val title = payload.optString("title")
            .trim()
            .replace(Regex("\\s+"), " ")
            .take(256)
            .ifBlank { null }
        val origin = when (payload.optString("kind").lowercase(Locale.ROOT)) {
            "video" -> CaptureOrigin.VIDEO
            "source" -> CaptureOrigin.SOURCE
            "script" -> CaptureOrigin.INLINE_SCRIPT
            "iframe" -> CaptureOrigin.IFRAME
            else -> CaptureOrigin.RUNTIME
        }
        val reference = CapturedMediaReference(
            url = targetUrl,
            pageUrl = pageUrl,
            requestReferer = requestReferer,
            title = title,
            thumbnailUrl = thumbnailUrl,
            iframeDepth = payload.optInt("iframeDepth", if (pageUrl == rootUrl) 0 else 1).coerceIn(0, 8),
            origin = origin,
        )
        rememberCookieUrl(pageUrl)
        rememberCookieUrl(targetUrl)
        record(reference)
    }

    private fun record(reference: CapturedMediaReference) {
        val key = "${canonical(reference.url)}\n${canonical(reference.pageUrl)}"
        val existing = references[key]
        if (existing != null) {
            duplicateCount += 1
            if (
                (existing.title == null && reference.title != null) ||
                (existing.thumbnailUrl == null && reference.thumbnailUrl != null) ||
                (existing.requestReferer == null && reference.requestReferer != null)
            ) {
                references[key] = existing.copy(
                    title = existing.title ?: reference.title,
                    thumbnailUrl = existing.thumbnailUrl ?: reference.thumbnailUrl,
                    requestReferer = existing.requestReferer ?: reference.requestReferer,
                )
            } else {
                return
            }
        } else {
            if (references.size >= MAXIMUM_REFERENCES) return
            references[key] = reference
            if (loggedReferenceCount < MAXIMUM_LOGGED_REFERENCES) {
                loggedReferenceCount += 1
                log(
                    "reference added origin=${reference.origin.name.lowercase()} " +
                        "depth=${reference.iframeDepth} thumbnail=${reference.thumbnailUrl != null} " +
                        DiagnosticPrivacy.urlSummary(reference.url),
                )
            }
        }
        _state.value = _state.value.copy(
            detectedCount = references.size,
            changeSequence = _state.value.changeSequence + 1,
        )
    }

    private inner class CaptureWebViewClient : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val target = request.url.toSafeHttpUrl()
            if (target == null || !NavigationSafety.isAllowed(rootUrl, target)) {
                blockedNavigationCount += 1
                log("capture navigation blocked by URL/private-network policy")
                return true
            }
            rememberCookieUrl(target)
            if (target.encodedPath.endsWith(".m3u8", ignoreCase = true)) {
                recordNavigationReference(target, request.isForMainFrame)
            }
            return false
        }

        override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest): WebResourceResponse? {
            val target = request.url.toSafeHttpUrl()
            if (target == null) {
                val internalScheme = request.url.scheme?.lowercase(Locale.ROOT) in setOf("about", "blob", "data")
                return if (internalScheme) null else blockedResourceResponse()
            }
            if (!NavigationSafety.isAllowed(rootUrl, target)) {
                blockedNavigationCount += 1
                return blockedResourceResponse()
            }
            if (target.encodedPath.endsWith(".m3u8", ignoreCase = true)) {
                mainScope.launch { recordNavigationReference(target, request.isForMainFrame) }
            }
            return null
        }

        override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
            val parsed = url?.toHttpUrlOrNull()
            parsed?.let(::rememberCookieUrl)
            _state.value = _state.value.copy(currentUrl = parsed ?: _state.value.currentUrl, isLoading = true)
            injectFallback(view)
            updateNavigationState()
        }

        override fun onPageFinished(view: WebView, url: String?) {
            val parsed = url?.toHttpUrlOrNull()
            parsed?.let(::rememberCookieUrl)
            _state.value = _state.value.copy(currentUrl = parsed ?: _state.value.currentUrl, isLoading = false)
            injectFallback(view)
            updateNavigationState()
            firstNavigationFinished.complete(Unit)
            log("capture navigation finished")
        }
    }

    private inner class CaptureChromeClient : WebChromeClient() {
        override fun onCreateWindow(
            view: WebView,
            isDialog: Boolean,
            isUserGesture: Boolean,
            resultMsg: Message,
        ): Boolean {
            if (!isUserGesture || stopped.get()) return false
            val popup = WebView(view.context)
            popup.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(popupView: WebView, request: WebResourceRequest): Boolean {
                    val target = request.url.toSafeHttpUrl()
                    if (target != null && NavigationSafety.isAllowed(rootUrl, target)) {
                        webView.loadUrl(target.toString())
                    } else {
                        blockedNavigationCount += 1
                    }
                    popupView.destroy()
                    return true
                }
            }
            val transport = resultMsg.obj as? WebView.WebViewTransport ?: return false
            transport.webView = popup
            resultMsg.sendToTarget()
            return true
        }
    }

    private fun recordNavigationReference(target: HttpUrl, isMainFrame: Boolean) {
        if (!NavigationSafety.isAllowed(rootUrl, target)) {
            blockedReferenceCount += 1
            return
        }
        val page = state.value.currentUrl ?: rootUrl
        record(
            CapturedMediaReference(
                url = target,
                pageUrl = page,
                requestReferer = page,
                title = null,
                thumbnailUrl = null,
                iframeDepth = if (isMainFrame) 0 else 1,
                origin = if (isMainFrame) CaptureOrigin.RUNTIME else CaptureOrigin.IFRAME,
            ),
        )
    }

    private fun injectFallback(view: WebView) {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            view.evaluateJavascript(DiscoveryScript.source(interactive), null)
        }
    }

    private fun blockedResourceResponse(): WebResourceResponse = WebResourceResponse(
        "text/plain",
        "utf-8",
        403,
        "Blocked by HLSDownloader",
        mapOf("Cache-Control" to "no-store"),
        ByteArrayInputStream(ByteArray(0)),
    )

    private fun updateNavigationState() {
        _state.value = _state.value.copy(
            canGoBack = webView.canGoBack(),
            canGoForward = webView.canGoForward(),
        )
    }

    private fun rememberCookieUrl(url: HttpUrl) {
        if (knownCookieUrls.size < MAXIMUM_REFERENCES * 2) knownCookieUrls += url
    }

    private fun canonical(url: HttpUrl): String = url.newBuilder().fragment(null).build().toString()

    private fun Uri.toSafeHttpUrl(): HttpUrl? {
        val parsed = toString().toHttpUrlOrNull() ?: return null
        return parsed.takeIf(HttpUrl::isSafeWebUrl)
    }

    private fun log(message: String) = diagnosticSink("webview", message)

}

private fun HttpUrl.isSafeWebUrl(): Boolean =
    (scheme == "http" || scheme == "https") && encodedUsername.isEmpty() && encodedPassword.isEmpty()

private object DiscoveryScript {
    fun source(interactive: Boolean): String = TEMPLATE.replace("__INTERACTIVE__", interactive.toString())

    private val TEMPLATE = """
        (() => {
          if (window.__hlsDownloaderProbeInstalled) return;
          window.__hlsDownloaderProbeInstalled = true;
          const interactive = __INTERACTIVE__;
          const bridge = window.HlsDiscoveryBridge;
          if (!bridge || typeof bridge.postMessage !== 'function') return;
          const posted = new Map();
          const maximumPostedEntries = 2048;
          const maximumBodyBytes = 64 * 1024;
          const maximumInspectableContentLength = 1024 * 1024;
          const hlsType = value => /(?:application|audio)\/(?:vnd\.apple\.mpegurl|x-mpegurl|mpegurl)/i.test(value || '');
          const decode = value => String(value == null ? '' : value)
            .replace(/\\\//g, '/')
            .replace(/\\u002f/gi, '/').replace(/\\u002e/gi, '.')
            .replace(/\\u003a/gi, ':').replace(/\\u003f/gi, '?')
            .replace(/\\u003d/gi, '=').replace(/\\u0026/gi, '&')
            .replace(/\\x2f/gi, '/').replace(/\\x2e/gi, '.');
          const absolute = (value, baseURL) => {
            const decoded = decode(value).trim();
            if (!decoded) return null;
            try { return new URL(decoded, baseURL || document.baseURI || location.href).href; }
            catch (_) { return null; }
          };
          const frameDepth = () => {
            try { return window.top === window ? 0 : 1; } catch (_) { return 1; }
          };
          const pagePoster = () => {
            try {
              const element = document.querySelector('meta[property="og:image"],meta[property="og:image:url"],meta[name="twitter:image"],meta[name="twitter:image:src"]');
              return element && element.getAttribute('content') || '';
            } catch (_) { return ''; }
          };
          const post = (value, kind, poster, title, force, baseURL) => {
            const url = absolute(value, baseURL);
            if (!url || !/^https?:/i.test(url)) return;
            if (!force && !/\.m3u8(?:$|[?#])/i.test(url)) return;
            const normalizedKind = kind || 'runtime';
            const normalizedPoster = absolute(poster || pagePoster() || '') || '';
            const normalizedTitle = String(title || document.title || '').slice(0, 256);
            const key = normalizedKind + '\n' + url;
            const signature = normalizedPoster + '\n' + normalizedTitle;
            if (posted.get(key) === signature) return;
            if (!posted.has(key) && posted.size >= maximumPostedEntries) {
              const oldest = posted.keys().next();
              if (!oldest.done) posted.delete(oldest.value);
            }
            posted.set(key, signature);
            try {
              bridge.postMessage(JSON.stringify({
                url: url,
                page: location.href,
                referrer: document.referrer || '',
                kind: normalizedKind,
                poster: normalizedPoster,
                title: normalizedTitle,
                iframeDepth: frameDepth()
              }));
            } catch (_) {}
          };
          const inspectText = (text, responseURL, kind) => {
            const sample = String(text || '').slice(0, maximumBodyBytes);
            if (!sample) return;
            const normalizedSample = decode(sample);
            if (/^\s*#EXTM3U/i.test(normalizedSample)) post(responseURL, kind || 'network', '', document.title, true);
            const matches = normalizedSample.match(/(?:https?:)?(?:\\?\/\\?\/|\.{0,2}\/)?[^\s\"'<>`]+?\.m3u8(?:\?[^\s\"'<>`]*)?/gi) || [];
            matches.slice(0, 64).forEach(value => post(value, kind || 'network', '', document.title, false, responseURL));
          };
          const shouldInspectResponseBody = (type, contentLength) => {
            const normalizedType = String(type || '').split(';', 1)[0].trim().toLowerCase();
            if (!normalizedType || /^(?:video|audio)\//.test(normalizedType) || hlsType(normalizedType)) return false;
            const parsedLength = /^\d+$/.test(String(contentLength || '').trim()) ? Number(contentLength) : null;
            if (parsedLength !== null && (!Number.isFinite(parsedLength) || parsedLength > maximumInspectableContentLength)) return false;
            const textual = normalizedType.startsWith('text/') || /(?:^|[+/])(?:json|xml)$/.test(normalizedType) || /javascript/.test(normalizedType);
            return textual || (normalizedType === 'application/octet-stream' && parsedLength !== null);
          };
          const inspectResponseBody = async (response, responseURL) => {
            let reader;
            try {
              const type = response.headers && response.headers.get('content-type') || '';
              const contentLength = response.headers && response.headers.get('content-length') || '';
              if (!shouldInspectResponseBody(type, contentLength)) return;
              const clone = response.clone();
              if (!clone.body || typeof clone.body.getReader !== 'function') return;
              reader = clone.body.getReader();
              const chunks = [];
              let total = 0;
              while (total < maximumBodyBytes) {
                const result = await reader.read();
                if (result.done) break;
                if (!result.value || !result.value.byteLength) continue;
                const remaining = maximumBodyBytes - total;
                const chunk = result.value.byteLength > remaining ? result.value.subarray(0, remaining) : result.value;
                chunks.push(chunk); total += chunk.byteLength;
              }
              if (!total) return;
              const bytes = new Uint8Array(total);
              let offset = 0;
              chunks.forEach(chunk => { bytes.set(chunk, offset); offset += chunk.byteLength; });
              inspectText(new TextDecoder('utf-8').decode(bytes), responseURL, 'network');
            } catch (_) {
            } finally {
              if (reader) { try { await reader.cancel(); } catch (_) {} }
            }
          };
          const scan = () => {
            try {
              document.querySelectorAll('video').forEach(video => {
                if (!interactive) { try { video.muted = true; video.playsInline = true; } catch (_) {} }
                const poster = video.poster || video.getAttribute('poster') || video.getAttribute('data-poster') || '';
                const title = video.getAttribute('title') || video.getAttribute('aria-label') || document.title || '';
                ['currentSrc', 'src'].forEach(name => post(video[name], 'video', poster, title, true));
                ['data-src', 'data-hls-src', 'data-video-src', 'data-playlist', 'data-file', 'data-url']
                  .forEach(name => post(video.getAttribute(name), 'video', poster, title, false));
                video.querySelectorAll('source').forEach(source => {
                  const type = source.type || source.getAttribute('type') || '';
                  ['src', 'data-src', 'data-hls-src', 'data-file', 'data-url']
                    .forEach(name => post(source.getAttribute(name), 'source', poster, title, hlsType(type)));
                });
              });
              document.querySelectorAll('source').forEach(source => {
                const type = source.type || source.getAttribute('type') || '';
                ['src', 'data-src', 'data-hls-src', 'data-file', 'data-url']
                  .forEach(name => post(source.getAttribute(name), 'source', '', document.title, hlsType(type)));
              });
              document.querySelectorAll('[src],[href],[data-src],[data-hls-src],[data-playlist],[data-file],[data-url]')
                .forEach(element => {
                  const type = element.getAttribute('type') || '';
                  ['src', 'href', 'data-src', 'data-hls-src', 'data-playlist', 'data-file', 'data-url']
                    .forEach(name => post(element.getAttribute(name), 'runtime', '', document.title, hlsType(type)));
                });
              document.querySelectorAll('script:not([src])').forEach(script => {
                const matches = (script.textContent || '').match(/(?:https?:)?(?:\\?\/\\?\/|\.{0,2}\/)?[^\s\"'<>`]+?\.m3u8(?:\?[^\s\"'<>`]*)?/gi) || [];
                matches.slice(0, 64).forEach(value => post(value, 'script', '', document.title, false));
              });
              if (window.performance && performance.getEntriesByType) {
                performance.getEntriesByType('resource').forEach(entry => post(entry.name, 'network', '', document.title, false));
              }
            } catch (_) {}
          };
          try {
            const originalFetch = window.fetch;
            if (originalFetch) {
              window.fetch = function() {
                const args = Array.from(arguments);
                const input = args[0];
                post(input && input.url ? input.url : input, 'network', '', document.title, false);
                return Reflect.apply(originalFetch, this, args).then(response => {
                  try {
                    const type = response.headers && response.headers.get('content-type');
                    const responseURL = response.url || (input && input.url ? input.url : input);
                    post(responseURL, 'network', '', document.title, hlsType(type));
                    void inspectResponseBody(response, responseURL);
                  } catch (_) {}
                  return response;
                });
              };
            }
          } catch (_) {}
          try {
            const originalOpen = XMLHttpRequest.prototype.open;
            const requestURL = Symbol('hlsDownloaderRequestURL');
            XMLHttpRequest.prototype.open = function(method, url) {
              const rest = Array.prototype.slice.call(arguments, 2);
              this[requestURL] = url;
              post(url, 'network', '', document.title, false);
              this.addEventListener('load', () => {
                try {
                  const type = this.getResponseHeader('content-type') || '';
                  let manifest = false;
                  if ((this.responseType === '' || this.responseType === 'text') && typeof this.responseText === 'string') {
                    const responseURL = this.responseURL || this[requestURL];
                    const sample = this.responseText.slice(0, maximumBodyBytes);
                    manifest = /^\s*#EXTM3U/i.test(sample);
                    inspectText(sample, responseURL, 'network');
                  }
                  post(this.responseURL || this[requestURL], 'network', '', document.title, manifest || hlsType(type));
                } catch (_) {}
              }, { once: true });
              return Reflect.apply(originalOpen, this, [method, url].concat(rest));
            };
          } catch (_) {}
          try {
            ['pushState', 'replaceState'].forEach(name => {
              const original = history[name];
              if (typeof original !== 'function') return;
              history[name] = function() {
                const result = Reflect.apply(original, this, arguments);
                setTimeout(scan, 0);
                return result;
              };
            });
            addEventListener('popstate', scan, true);
            addEventListener('hashchange', scan, true);
          } catch (_) {}
          const installObservers = () => {
            scan();
            try {
              let pending = false;
              new MutationObserver(() => {
                if (pending) return;
                pending = true;
                setTimeout(() => { pending = false; scan(); }, 50);
              }).observe(document.documentElement || document, { subtree: true, childList: true, attributes: true });
            } catch (_) {}
            try {
              new PerformanceObserver(list => list.getEntries().forEach(entry => post(entry.name, 'network', '', document.title, false)))
                .observe({ type: 'resource', buffered: true });
            } catch (_) {}
            document.addEventListener('loadstart', scan, true);
            document.addEventListener('loadedmetadata', scan, true);
            setInterval(scan, interactive ? 2000 : 750);
          };
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', installObservers, { once: true });
          else installObservers();
        })();
    """.trimIndent()
}
