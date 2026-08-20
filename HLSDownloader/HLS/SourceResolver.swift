import Foundation

final class SourceResolver: Sendable {
    private enum DocumentSource: Sendable {
        case loaded(String, URL)
        case remote(URL)
    }

    private struct DocumentWork: Sendable {
        let source: DocumentSource
        let referer: URL?
        let iframeDepth: Int
        let inheritedTitle: String?
        let inheritedThumbnailURL: URL?
    }

    private let client: HTTPClient
    private let dynamicInspector: (any DynamicPageInspecting)?
    private let diagnosticSink: DiagnosticSink?
    private let maximumHTMLBytes = 8 * 1_024 * 1_024
    private let maximumDocuments = 16
    private let maximumIframeDepth = 3
    private let maximumFramesPerDocument = 12
    private let maximumCandidateReferences = 128
    private let maximumResults = 64

    init(
        client: HTTPClient,
        dynamicInspector: (any DynamicPageInspecting)? = nil,
        diagnosticSink: DiagnosticSink? = nil
    ) {
        self.client = client
        self.dynamicInspector = dynamicInspector
        self.diagnosticSink = diagnosticSink
    }

    func discover(input: String) async throws -> HLSDiscoveryResult {
        let inputURL = try URIResolver.normalizeInput(input)
        log("discovery", "start \(DiagnosticPrivacy.urlSummary(inputURL))")

        var initialProbe: HTTPResourceProbe?
        do {
            let probe = try await client.probeMediaPrefix(inputURL)
            initialProbe = probe
            guard AutomaticNavigationPolicy.isAllowedFrameNavigation(
                from: inputURL,
                to: probe.effectiveURL
            ) else {
                throw HLSError.network("progressive media redirect was blocked")
            }
            if let container = ProgressiveMediaDetector.detect(
                prefix: probe.prefix,
                url: probe.effectiveURL,
                mimeType: probe.mimeType
            ) {
                guard ProgressiveMediaDetector.supportsStandaloneDownload(container) else {
                    log("progressive", "standalone framed HLS media rejected because encryption cannot be authenticated without a manifest")
                    throw HLSError.drmUnsupported("standalone TS/AAC/AC-3 requires an HLS manifest")
                }
                log(
                    "progressive",
                    "direct media accepted container=\(container.rawValue) bytesProbed=\(probe.prefix.count) \(DiagnosticPrivacy.urlSummary(probe.effectiveURL))"
                )
                return HLSDiscoveryResult(
                    candidates: [
                        HLSCandidate(
                            id: UUID(),
                            kind: .progressive,
                            request: URLCandidates(
                                primary: inputURL,
                                sameOriginQueryFallback: nil
                            ),
                            requestReferer: inputURL,
                            document: nil,
                            progressiveMedia: ProgressiveMediaReference(
                                storage: .remote,
                                hintedMIMEType: probe.mimeType,
                                validatedEffectiveURL: probe.effectiveURL,
                                container: container,
                                resolution: ProgressiveMediaResolutionProbe.detect(
                                    prefix: probe.prefix,
                                    container: container
                                ),
                                validatedPrefixSHA256: ProgressiveMediaFingerprint.sha256(
                                    probe.prefix
                                ),
                                validatedPrefixByteCount: probe.prefix.count
                            ),
                            pageURL: probe.effectiveURL,
                            title: nil,
                            thumbnailURL: nil,
                            iframeDepth: 0,
                            origin: .direct
                        )
                    ],
                    isDirectPlaylist: false
                )
            }
        } catch is CancellationError {
            throw HLSError.cancelled
        } catch let error as HLSError {
            if case .cancelled = error { throw error }
            if case .drmUnsupported = error { throw error }
            log("progressive", "direct media probe skipped error=\(DiagnosticPrivacy.errorCode(error))")
        } catch {
            log("progressive", "direct media probe skipped error=\(DiagnosticPrivacy.errorCode(error))")
        }

        let payload: HTTPPayload
        do {
            if let initialProbe, initialProbe.isCompleteResponse {
                payload = HTTPPayload(
                    data: initialProbe.prefix,
                    effectiveURL: initialProbe.effectiveURL,
                    statusCode: initialProbe.statusCode,
                    mimeType: initialProbe.mimeType
                )
            } else {
                payload = try await client.fetch(inputURL)
            }
            log(
                "network",
                "root response status=\(payload.statusCode) mime=\(DiagnosticPrivacy.mimeClass(payload.mimeType)) bytes=\(payload.data.count) redirected=\(payload.effectiveURL != inputURL) \(DiagnosticPrivacy.urlSummary(payload.effectiveURL))"
            )
        } catch {
            if error is CancellationError { throw HLSError.cancelled }
            if let hlsError = error as? HLSError, case .cancelled = hlsError {
                throw hlsError
            }
            log("network", "root failed error=\(DiagnosticPrivacy.errorCode(error)); trying WebKit fallback")
            let originalError = error
            let candidates = try await dynamicallyDiscoveredCandidates(rootURL: inputURL)
            if !candidates.isEmpty {
                log("discovery", "finish dynamicOnly=true candidates=\(candidates.count)")
                return HLSDiscoveryResult(candidates: candidates, isDirectPlaylist: false)
            }
            log("discovery", "finish failed error=\(DiagnosticPrivacy.errorCode(originalError))")
            throw originalError
        }
        guard AutomaticNavigationPolicy.isAllowedFrameNavigation(
            from: inputURL,
            to: payload.effectiveURL
        ) else {
            log("security", "blocked root redirect to local/private target")
            throw HLSError.network("公開URLからローカルネットワークへのリダイレクトを拒否しました")
        }
        guard let text = decodeText(payload.data) else {
            log("discovery", "root text decode failed; trying WebKit fallback")
            let candidates = try await dynamicallyDiscoveredCandidates(rootURL: payload.effectiveURL)
            guard !candidates.isEmpty else { throw HLSError.noPlaylistFound }
            log("discovery", "finish dynamicOnly=true candidates=\(candidates.count)")
            return HLSDiscoveryResult(candidates: candidates, isDirectPlaylist: false)
        }

        if PlaylistParser.isPlaylist(text) {
            log("discovery", "direct playlist accepted")
            let document = PlaylistDocument(
                text: text,
                effectiveURL: payload.effectiveURL,
                referer: inputURL
            )
            return HLSDiscoveryResult(
                candidates: [
                    HLSCandidate(
                        id: UUID(),
                        kind: .hls,
                        request: URLCandidates(
                            primary: payload.effectiveURL,
                            sameOriginQueryFallback: nil
                        ),
                        requestReferer: inputURL,
                        document: document,
                        pageURL: payload.effectiveURL,
                        title: nil,
                        thumbnailURL: nil,
                        iframeDepth: 0,
                        origin: .direct
                    )
                ],
                isDirectPlaylist: true
            )
        }

        if isDASHPayload(payload) {
            guard DASHManifestParser.isMPD(payload.data) else {
                log("widevine", "direct MPD rejected because the manifest is invalid")
                throw HLSError.invalidPlaylist("MPEG-DASH MPDが不正です")
            }
            let manifest = try DASHManifestParser.parse(
                data: payload.data,
                effectiveURL: payload.effectiveURL
            )
            guard manifest.isWidevine else {
                log("widevine", "direct MPD rejected because Widevine ContentProtection was not found")
                throw HLSError.invalidPlaylist("Widevine ContentProtectionのないMPDには対応していません")
            }
            guard isDownloadableWidevineDomain(inputURL),
                  isDownloadableWidevineDomain(payload.effectiveURL) else {
                log(
                    "widevine",
                    "direct Widevine MPD rejected by download-domain policy redirected=\(payload.effectiveURL != inputURL) \(DiagnosticPrivacy.urlSummary(payload.effectiveURL))"
                )
                throw HLSError.drmUnsupported("Widevine DASH (許可ドメイン外)")
            }
            let document = PlaylistDocument(
                text: text,
                effectiveURL: payload.effectiveURL,
                referer: inputURL
            )
            log("widevine", "direct Widevine MPD accepted \(DiagnosticPrivacy.urlSummary(payload.effectiveURL))")
            return HLSDiscoveryResult(
                candidates: [
                    HLSCandidate(
                        id: UUID(),
                        kind: .widevineDASH,
                        request: URLCandidates(
                            primary: payload.effectiveURL,
                            sameOriginQueryFallback: nil
                        ),
                        requestReferer: inputURL,
                        document: document,
                        pageURL: payload.effectiveURL,
                        title: nil,
                        thumbnailURL: nil,
                        iframeDepth: 0,
                        origin: .direct
                    )
                ],
                isDirectPlaylist: true
            )
        }

        guard payload.data.count <= maximumHTMLBytes else {
            log("discovery", "root HTML exceeded byte limit; trying WebKit fallback")
            let candidates = try await dynamicallyDiscoveredCandidates(rootURL: payload.effectiveURL)
            guard !candidates.isEmpty else { throw HLSError.htmlTooLarge }
            log("discovery", "finish dynamicOnly=true candidates=\(candidates.count)")
            return HLSDiscoveryResult(candidates: candidates, isDirectPlaylist: false)
        }
        let candidates = try await discoverInHTML(
            rootHTML: text,
            rootURL: payload.effectiveURL,
            rootReferer: inputURL
        )
        guard !candidates.isEmpty else { throw HLSError.noPlaylistFound }
        log("discovery", "finish direct=false candidates=\(candidates.count)")
        return HLSDiscoveryResult(candidates: candidates, isDirectPlaylist: false)
    }

    func resolve(input: String) async throws -> PlaylistDocument {
        let discovery = try await discover(input: input)
        guard let first = discovery.candidates.first else { throw HLSError.noPlaylistFound }
        if let document = first.document { return document }
        return try await load(first.request, referer: first.requestReferer)
    }

    func importDynamicInspection(
        _ inspection: DynamicPageInspection,
        rootURL: URL
    ) async -> [HLSCandidate] {
        guard !Task.isCancelled else {
            inspection.blobs.forEach {
                WebBlobCaptureStore.discardCaptureFile(at: $0.fileURL)
            }
            return []
        }
        client.storeCookies(inspection.cookies)
        var discovered = Set<String>()
        var accepted = Set<String>()
        var results: [HLSCandidate] = []
        await appendDynamicCandidates(
            inspection,
            rootURL: rootURL,
            discovered: &discovered,
            accepted: &accepted,
            results: &results
        )
        log(
            "playback",
            "interactive inspection imported references=\(inspection.media.count) licenseMetadata=\(inspection.licenseRequests.count) eme=\(inspection.detectedWidevineKeySystem) candidates=\(results.count) cookies=\(inspection.cookies.count)"
        )
        return results
    }

    func load(_ candidates: URLCandidates, referer: URL?) async throws -> PlaylistDocument {
        var lastError: Error = HLSError.invalidPlaylist("リンク先がm3u8ではありません")
        for candidate in candidates.all {
            do {
                log("playlist", "validate \(DiagnosticPrivacy.urlSummary(candidate))")
                let payload = try await client.fetch(candidate, referer: referer)
                guard let text = decodeText(payload.data), PlaylistParser.isPlaylist(text) else {
                    throw HLSError.invalidPlaylist("リンク先がm3u8ではありません")
                }
                log(
                    "playlist",
                    "accepted status=\(payload.statusCode) bytes=\(payload.data.count) \(DiagnosticPrivacy.urlSummary(payload.effectiveURL))"
                )
                return PlaylistDocument(text: text, effectiveURL: payload.effectiveURL, referer: referer)
            } catch is CancellationError {
                throw HLSError.cancelled
            } catch let error as HLSError {
                if case .cancelled = error { throw error }
                log("playlist", "candidate rejected error=\(DiagnosticPrivacy.errorCode(error))")
                lastError = error
            } catch {
                log("playlist", "candidate failed error=\(DiagnosticPrivacy.errorCode(error))")
                lastError = error
            }
        }
        throw lastError
    }

    private func discoverInHTML(
        rootHTML: String,
        rootURL: URL,
        rootReferer: URL?
    ) async throws -> [HLSCandidate] {
        async let dynamicInspection = inspectDynamically(rootURL)
        log(
            "discovery",
            "HTML scan start maxDocuments=\(maximumDocuments) maxDepth=\(maximumIframeDepth) maxResults=\(maximumResults)"
        )

        var queue = [
            DocumentWork(
                source: .loaded(rootHTML, rootURL),
                referer: rootReferer,
                iframeDepth: 0,
                inheritedTitle: nil,
                inheritedThumbnailURL: nil
            )
        ]
        var queueIndex = 0
        var processedDocuments = 0
        var visitedRemoteDocuments: Set<String> = [canonicalURLKey(rootURL)]
        var discoveredCandidates = Set<String>()
        var acceptedCandidates = Set<String>()
        var results: [HLSCandidate] = []

        while queueIndex < queue.count,
              processedDocuments < maximumDocuments,
              results.count < maximumResults {
            try Task.checkCancellation()
            let work = queue[queueIndex]
            queueIndex += 1

            let html: String
            let documentURL: URL
            switch work.source {
            case .loaded(let loadedHTML, let loadedURL):
                processedDocuments += 1
                html = loadedHTML
                documentURL = loadedURL

            case .remote(let requestedURL):
                let requestedKey = canonicalURLKey(requestedURL)
                guard visitedRemoteDocuments.insert(requestedKey).inserted else { continue }
                processedDocuments += 1

                do {
                    log(
                        "iframe",
                        "fetch depth=\(work.iframeDepth) \(DiagnosticPrivacy.urlSummary(requestedURL))"
                    )
                    let payload = try await client.fetch(requestedURL, referer: work.referer)
                    guard AutomaticNavigationPolicy.isAllowedNativeFrameNavigation(
                        from: rootURL,
                        to: payload.effectiveURL
                    ) else {
                        log("iframe", "blocked by navigation policy depth=\(work.iframeDepth)")
                        continue
                    }
                    let effectiveKey = canonicalURLKey(payload.effectiveURL)
                    if effectiveKey != requestedKey,
                       !visitedRemoteDocuments.insert(effectiveKey).inserted {
                        continue
                    }
                    guard let fetchedText = decodeText(payload.data) else {
                        log("iframe", "decode failed depth=\(work.iframeDepth) bytes=\(payload.data.count)")
                        continue
                    }
                    if PlaylistParser.isPlaylist(fetchedText) {
                        let document = PlaylistDocument(
                            text: fetchedText,
                            effectiveURL: payload.effectiveURL,
                            referer: work.referer
                        )
                        appendCandidate(
                            kind: .hls,
                            request: URLCandidates(
                                primary: payload.effectiveURL,
                                sameOriginQueryFallback: nil
                            ),
                            requestReferer: work.referer,
                            document: document,
                            pageURL: work.referer ?? payload.effectiveURL,
                            title: work.inheritedTitle,
                            thumbnailURL: work.inheritedThumbnailURL,
                            iframeDepth: work.iframeDepth,
                            origin: .iframe,
                            accepted: &acceptedCandidates,
                            results: &results
                        )
                        continue
                    }
                    if isDASHPayload(payload) {
                        do {
                            let document = try validateWidevineDASHPayload(
                                payload,
                                requestedURL: requestedURL,
                                referer: work.referer
                            )
                            appendCandidate(
                                kind: .widevineDASH,
                                request: URLCandidates(
                                    primary: payload.effectiveURL,
                                    sameOriginQueryFallback: nil
                                ),
                                requestReferer: work.referer,
                                document: document,
                                pageURL: work.referer ?? payload.effectiveURL,
                                title: work.inheritedTitle,
                                thumbnailURL: work.inheritedThumbnailURL,
                                iframeDepth: work.iframeDepth,
                                origin: .iframe,
                                accepted: &acceptedCandidates,
                                results: &results
                            )
                        } catch {
                            log(
                                "widevine",
                                "iframe MPD rejected depth=\(work.iframeDepth) error=\(DiagnosticPrivacy.errorCode(error))"
                            )
                        }
                        continue
                    }
                    guard payload.data.count <= maximumHTMLBytes else {
                        log("iframe", "HTML byte limit exceeded depth=\(work.iframeDepth) bytes=\(payload.data.count)")
                        continue
                    }
                    html = fetchedText
                    documentURL = payload.effectiveURL
                } catch is CancellationError {
                    throw HLSError.cancelled
                } catch let error as HLSError {
                    if case .cancelled = error { throw error }
                    log("iframe", "fetch failed depth=\(work.iframeDepth) error=\(DiagnosticPrivacy.errorCode(error))")
                    continue
                } catch {
                    log("iframe", "fetch failed depth=\(work.iframeDepth) error=\(DiagnosticPrivacy.errorCode(error))")
                    continue
                }
            }

            let extraction = HTMLMediaExtractor.extract(from: html)
            log(
                "discovery",
                "document depth=\(work.iframeDepth) media=\(extraction.media.count) frames=\(extraction.frames.count) base=\(extraction.baseHref != nil) poster=\(extraction.rawThumbnailURL != nil)"
            )
            let documentBaseURL = resolvedAutomaticURL(
                extraction.baseHref,
                relativeTo: documentURL
            ) ?? documentURL
            let pageTitle = limitedTitle(extraction.title ?? work.inheritedTitle)
            let resolvedPageThumbnailURL = resolvedAutomaticURL(
                extraction.rawThumbnailURL,
                relativeTo: documentBaseURL
            ) ?? work.inheritedThumbnailURL
            let pageThumbnailURL = resolvedPageThumbnailURL.flatMap {
                AutomaticNavigationPolicy.isAllowedFrameNavigation(from: rootURL, to: $0) ? $0 : nil
            }
            let mediaGroupNamespace = UUID().uuidString

            for reference in extraction.media where results.count < maximumResults {
                guard discoveredCandidates.count < maximumCandidateReferences else { break }
                let request: URLCandidates
                do {
                    request = try URIResolver.resolve(
                        reference.rawURL,
                        relativeTo: documentBaseURL,
                        queryFallbackSource: documentURL
                    )
                } catch {
                    continue
                }
                guard isSafeAutomaticURL(request.primary) else { continue }
                let attemptKey = candidateKey(
                    kind: reference.kind,
                    url: request.primary,
                    referer: documentURL
                )
                guard discoveredCandidates.insert(attemptKey).inserted else { continue }

                let resolvedThumbnailURL = resolvedAutomaticURL(
                    reference.rawPosterURL,
                    relativeTo: documentBaseURL
                ) ?? pageThumbnailURL
                let thumbnailURL = resolvedThumbnailURL.flatMap {
                    AutomaticNavigationPolicy.isAllowedFrameNavigation(from: rootURL, to: $0) ? $0 : nil
                }
                switch reference.kind {
                case .hls:
                    let inspectedDocument = await inspectHLSPlaylist(
                        request,
                        referer: documentURL,
                        rootURL: rootURL
                    )
                    appendCandidate(
                        kind: .hls,
                        request: request,
                        requestReferer: documentURL,
                        document: inspectedDocument,
                        pageURL: documentURL,
                        title: limitedTitle(reference.title ?? pageTitle),
                        thumbnailURL: thumbnailURL,
                        iframeDepth: work.iframeDepth,
                        origin: reference.origin,
                        accepted: &acceptedCandidates,
                        results: &results
                    )
                case .widevineDASH:
                    do {
                        let validated = try await loadWidevineDASH(
                            request,
                            referer: documentURL,
                            rootURL: rootURL
                        )
                        appendCandidate(
                            kind: validated.kind,
                            request: validated.request,
                            requestReferer: documentURL,
                            document: validated.document,
                            pageURL: documentURL,
                            title: limitedTitle(reference.title ?? pageTitle),
                            thumbnailURL: thumbnailURL,
                            iframeDepth: work.iframeDepth,
                            origin: reference.origin,
                            accepted: &acceptedCandidates,
                            results: &results
                        )
                    } catch is CancellationError {
                        throw HLSError.cancelled
                    } catch let error as HLSError {
                        if case .cancelled = error { throw error }
                        log("widevine", "HTML MPD candidate rejected error=\(DiagnosticPrivacy.errorCode(error))")
                    } catch {
                        log("widevine", "HTML MPD candidate rejected error=\(DiagnosticPrivacy.errorCode(error))")
                    }
                case .progressive:
                    do {
                        let validated = try await probeProgressiveMedia(
                            request,
                            referer: documentURL,
                            rootURL: rootURL
                        )
                        appendCandidate(
                            kind: .progressive,
                            request: validated.request,
                            requestReferer: documentURL,
                            document: nil,
                            progressiveMedia: ProgressiveMediaReference(
                                storage: .remote,
                                hintedMIMEType: validated.mimeType,
                                validatedEffectiveURL: validated.effectiveURL,
                                container: validated.container,
                                resolution: validated.resolution,
                                validatedPrefixSHA256: validated.prefixSHA256,
                                validatedPrefixByteCount: validated.prefixByteCount
                            ),
                            mediaGroupID: reference.mediaGroupID.map {
                                "\(mediaGroupNamespace):\($0)"
                            },
                            pageURL: documentURL,
                            title: limitedTitle(reference.title ?? pageTitle),
                            thumbnailURL: thumbnailURL,
                            iframeDepth: work.iframeDepth,
                            origin: reference.origin,
                            accepted: &acceptedCandidates,
                            results: &results
                        )
                    } catch is CancellationError {
                        throw HLSError.cancelled
                    } catch let error as HLSError {
                        if case .cancelled = error { throw error }
                        log("progressive", "HTML media candidate rejected error=\(DiagnosticPrivacy.errorCode(error))")
                    } catch {
                        log("progressive", "HTML media candidate rejected error=\(DiagnosticPrivacy.errorCode(error))")
                    }
                }
            }

            guard work.iframeDepth < maximumIframeDepth else {
                if !extraction.frames.isEmpty {
                    log("iframe", "depth limit reached depth=\(work.iframeDepth) droppedFrames=\(extraction.frames.count)")
                }
                continue
            }
            if extraction.frames.count > maximumFramesPerDocument {
                log(
                    "iframe",
                    "per-document frame limit reached total=\(extraction.frames.count) accepted=\(maximumFramesPerDocument)"
                )
            }
            for frame in extraction.frames.prefix(maximumFramesPerDocument) {
                let inheritedTitle = limitedTitle(frame.title ?? pageTitle)
                if let sourceDocument = frame.sourceDocument {
                    queue.append(
                        DocumentWork(
                            source: .loaded(sourceDocument, documentBaseURL),
                            referer: documentURL,
                            iframeDepth: work.iframeDepth + 1,
                            inheritedTitle: inheritedTitle,
                            inheritedThumbnailURL: pageThumbnailURL
                        )
                    )
                } else if let frameURL = resolvedAutomaticURL(
                    frame.rawURL,
                    relativeTo: documentBaseURL
                ) {
                    if AutomaticNavigationPolicy.isAllowedNativeFrameNavigation(
                        from: rootURL,
                        to: frameURL
                    ) {
                        queue.append(
                            DocumentWork(
                                source: .remote(frameURL),
                                referer: documentURL,
                                iframeDepth: work.iframeDepth + 1,
                                inheritedTitle: inheritedTitle,
                                inheritedThumbnailURL: pageThumbnailURL
                            )
                        )
                    } else {
                        log("iframe", "automatic fetch blocked by origin/private-network policy")
                    }
                } else if frame.rawURL != nil {
                    log("iframe", "invalid or unsupported frame URL")
                }
            }
        }

        let dynamic = await dynamicInspection
        guard !Task.isCancelled else {
            dynamic.blobs.forEach {
                WebBlobCaptureStore.discardCaptureFile(at: $0.fileURL)
            }
            throw HLSError.cancelled
        }
        log(
            "webkit",
            "inspection returned references=\(dynamic.media.count) blobs=\(dynamic.blobs.count) mse=\(dynamic.detectedMediaSource) licenseMetadata=\(dynamic.licenseRequests.count) eme=\(dynamic.detectedWidevineKeySystem) cookies=\(dynamic.cookies.count)"
        )
        client.storeCookies(dynamic.cookies)

        await appendDynamicCandidates(
            dynamic,
            rootURL: rootURL,
            discovered: &discoveredCandidates,
            accepted: &acceptedCandidates,
            results: &results
        )

        log(
            "discovery",
            "HTML scan finish documents=\(processedDocuments) queued=\(queue.count) discovered=\(discoveredCandidates.count) results=\(results.count) documentLimit=\(processedDocuments >= maximumDocuments) resultLimit=\(results.count >= maximumResults)"
        )
        return results
    }

    private func inspectDynamically(_ url: URL) async -> DynamicPageInspection {
        guard let dynamicInspector else {
            log("webkit", "dynamic inspection unavailable")
            return .empty
        }
        let seedCookies = client.cookies(for: url)
        log("webkit", "inspection start seedCookies=\(seedCookies.count) \(DiagnosticPrivacy.urlSummary(url))")
        let result = await dynamicInspector.inspect(url: url, seedCookies: seedCookies)
        log(
            "webkit",
            "inspection finish references=\(result.media.count) blobs=\(result.blobs.count) mse=\(result.detectedMediaSource) licenseMetadata=\(result.licenseRequests.count) eme=\(result.detectedWidevineKeySystem) cookies=\(result.cookies.count)"
        )
        return result
    }

    private func dynamicallyDiscoveredCandidates(rootURL: URL) async throws -> [HLSCandidate] {
        let dynamic = await inspectDynamically(rootURL)
        guard !Task.isCancelled else {
            dynamic.blobs.forEach {
                WebBlobCaptureStore.discardCaptureFile(at: $0.fileURL)
            }
            throw HLSError.cancelled
        }
        client.storeCookies(dynamic.cookies)
        var discovered = Set<String>()
        var accepted = Set<String>()
        var results: [HLSCandidate] = []
        await appendDynamicCandidates(
            dynamic,
            rootURL: rootURL,
            discovered: &discovered,
            accepted: &accepted,
            results: &results
        )
        return results
    }

    private func appendDynamicCandidates(
        _ inspection: DynamicPageInspection,
        rootURL: URL,
        discovered: inout Set<String>,
        accepted: inout Set<String>,
        results: inout [HLSCandidate]
    ) async {
        var blobContextIndices: [Int: Int] = [:]
        var mediaForContext = inspection.media
        for (blobIndex, blob) in inspection.blobs.enumerated() where blob.kind == .widevineDASH {
            blobContextIndices[blobIndex] = mediaForContext.count
            mediaForContext.append(
                DynamicMediaReference(
                    url: blob.pageURL,
                    kind: .widevineDASH,
                    pageURL: blob.pageURL,
                    title: blob.title,
                    thumbnailURL: nil,
                    iframeDepth: blob.iframeDepth,
                    origin: .runtime,
                    frameToken: blob.frameToken,
                    sequence: blob.sequence
                )
            )
        }
        let contextInspection = DynamicPageInspection(
            media: mediaForContext,
            blobs: inspection.blobs,
            cookies: inspection.cookies,
            licenseRequests: inspection.licenseRequests,
            detectedWidevineKeySystem: inspection.detectedWidevineKeySystem,
            detectedMediaSource: inspection.detectedMediaSource
        )
        let playbackContexts = widevinePlaybackContexts(
            in: contextInspection,
            rootURL: rootURL
        )
        for (referenceIndex, reference) in inspection.media.enumerated()
            where results.count < maximumResults {
            guard discovered.count < maximumCandidateReferences else { break }
            guard isSafeAutomaticURL(reference.url),
                  AutomaticNavigationPolicy.isAllowedFrameNavigation(
                    from: rootURL,
                    to: reference.url
                  ) else {
                log("security", "dynamic candidate blocked by private-network policy")
                continue
            }
            let pageURL = isSafeAutomaticURL(reference.pageURL) ? reference.pageURL : rootURL
            let attemptKey = candidateKey(
                kind: reference.kind,
                url: reference.url,
                referer: pageURL
            )
            let thumbnailURL = reference.thumbnailURL.flatMap {
                isSafeAutomaticURL($0)
                    && AutomaticNavigationPolicy.isAllowedFrameNavigation(from: rootURL, to: $0)
                    ? $0 : nil
            }
            let dynamicRequest = URLCandidates(
                primary: reference.url,
                sameOriginQueryFallback: nil
            )
            if !discovered.insert(attemptKey).inserted {
                if reference.kind == .hls,
                   let inspectedDocument = await inspectHLSPlaylist(
                    dynamicRequest,
                    referer: pageURL,
                    rootURL: rootURL
                   ) {
                    appendCandidate(
                        kind: .hls,
                        request: dynamicRequest,
                        requestReferer: pageURL,
                        document: inspectedDocument,
                        pageURL: pageURL,
                        title: limitedTitle(reference.title),
                        thumbnailURL: thumbnailURL,
                        iframeDepth: reference.iframeDepth,
                        origin: reference.origin,
                        accepted: &accepted,
                        results: &results
                    )
                }
                continue
            }
            switch reference.kind {
            case .hls:
                let inspectedDocument = await inspectHLSPlaylist(
                    dynamicRequest,
                    referer: pageURL,
                    rootURL: rootURL
                )
                appendCandidate(
                    kind: .hls,
                    request: dynamicRequest,
                    requestReferer: pageURL,
                    document: inspectedDocument,
                    pageURL: pageURL,
                    title: limitedTitle(reference.title),
                    thumbnailURL: thumbnailURL,
                    iframeDepth: reference.iframeDepth,
                    origin: reference.origin,
                    accepted: &accepted,
                    results: &results
                )
            case .widevineDASH:
                do {
                    let validated = try await loadWidevineDASH(
                        dynamicRequest,
                        referer: pageURL,
                        rootURL: rootURL
                    )
                    appendCandidate(
                        kind: validated.kind,
                        request: validated.request,
                        requestReferer: pageURL,
                        document: validated.document,
                        widevinePlaybackContext: playbackContexts[referenceIndex],
                        pageURL: pageURL,
                        title: limitedTitle(reference.title),
                        thumbnailURL: thumbnailURL,
                        iframeDepth: reference.iframeDepth,
                        origin: reference.origin,
                        accepted: &accepted,
                        results: &results
                    )
                } catch is CancellationError {
                    inspection.blobs.forEach {
                        WebBlobCaptureStore.discardCaptureFile(at: $0.fileURL)
                    }
                    return
                } catch let error as HLSError {
                    if case .cancelled = error {
                        inspection.blobs.forEach {
                            WebBlobCaptureStore.discardCaptureFile(at: $0.fileURL)
                        }
                        return
                    }
                    log("widevine", "dynamic MPD candidate rejected error=\(DiagnosticPrivacy.errorCode(error))")
                } catch {
                    log("widevine", "dynamic MPD candidate rejected error=\(DiagnosticPrivacy.errorCode(error))")
                }
            case .progressive:
                do {
                    let validated = try await probeProgressiveMedia(
                        dynamicRequest,
                        referer: pageURL,
                        rootURL: rootURL
                    )
                    appendCandidate(
                        kind: .progressive,
                        request: validated.request,
                        requestReferer: pageURL,
                        document: nil,
                        progressiveMedia: ProgressiveMediaReference(
                            storage: .remote,
                            hintedMIMEType: validated.mimeType,
                            validatedEffectiveURL: validated.effectiveURL,
                            container: validated.container,
                            resolution: validated.resolution,
                            validatedPrefixSHA256: validated.prefixSHA256,
                            validatedPrefixByteCount: validated.prefixByteCount
                        ),
                        mediaGroupID: reference.mediaGroupID.flatMap { groupID in
                            reference.frameToken.map { "\($0):\(groupID)" }
                        },
                        pageURL: pageURL,
                        title: limitedTitle(reference.title),
                        thumbnailURL: thumbnailURL,
                        iframeDepth: reference.iframeDepth,
                        origin: reference.origin,
                        accepted: &accepted,
                        results: &results
                    )
                } catch is CancellationError {
                    inspection.blobs.forEach {
                        WebBlobCaptureStore.discardCaptureFile(at: $0.fileURL)
                    }
                    return
                } catch let error as HLSError {
                    if case .cancelled = error {
                        inspection.blobs.forEach {
                            WebBlobCaptureStore.discardCaptureFile(at: $0.fileURL)
                        }
                        return
                    }
                    log("progressive", "dynamic media candidate rejected error=\(DiagnosticPrivacy.errorCode(error))")
                } catch {
                    log("progressive", "dynamic media candidate rejected error=\(DiagnosticPrivacy.errorCode(error))")
                }
            }
        }

        guard !Task.isCancelled else {
            inspection.blobs.forEach {
                WebBlobCaptureStore.discardCaptureFile(at: $0.fileURL)
            }
            return
        }
        for (blobIndex, blob) in inspection.blobs.enumerated() {
            guard results.count < maximumResults else {
                WebBlobCaptureStore.discardCaptureFile(at: blob.fileURL)
                continue
            }
            guard WebBlobCaptureStore.isManagedCaptureURL(blob.fileURL),
                  isSafeAutomaticURL(blob.pageURL),
                  AutomaticNavigationPolicy.isAllowedFrameNavigation(
                    from: rootURL,
                    to: blob.pageURL
              ) else {
                log("security", "captured Blob candidate blocked by origin policy")
                WebBlobCaptureStore.discardCaptureFile(at: blob.fileURL)
                continue
            }

            switch blob.kind {
            case .hls:
                guard let text = capturedManifestText(blob),
                      PlaylistParser.isPlaylist(text) else {
                    log("webkit", "captured HLS Blob rejected because its body is invalid")
                    WebBlobCaptureStore.discardCaptureFile(at: blob.fileURL)
                    continue
                }
                let document = PlaylistDocument(
                    text: text,
                    effectiveURL: blob.pageURL,
                    referer: blob.pageURL
                )
                appendCandidate(
                    kind: .hls,
                    request: URLCandidates(primary: blob.pageURL, sameOriginQueryFallback: nil),
                    requestReferer: blob.pageURL,
                    document: document,
                    usesCapturedDocument: true,
                    capturedContentID: blob.capturedContentID,
                    pageURL: blob.pageURL,
                    title: limitedTitle(blob.title),
                    thumbnailURL: nil,
                    iframeDepth: blob.iframeDepth,
                    origin: .runtime,
                    accepted: &accepted,
                    results: &results
                )
                WebBlobCaptureStore.discardCaptureFile(at: blob.fileURL)

            case .widevineDASH:
                guard isDownloadableWidevineDomain(blob.pageURL),
                      let data = capturedManifestData(blob),
                      let text = decodeText(data),
                      let manifest = try? DASHManifestParser.parse(
                        data: data,
                        effectiveURL: blob.pageURL
                      ),
                      manifest.isWidevine else {
                    log("widevine", "captured MPD Blob rejected by validation/domain policy")
                    WebBlobCaptureStore.discardCaptureFile(at: blob.fileURL)
                    continue
                }
                let document = PlaylistDocument(
                    text: text,
                    effectiveURL: blob.pageURL,
                    referer: blob.pageURL
                )
                appendCandidate(
                    kind: .widevineDASH,
                    request: URLCandidates(primary: blob.pageURL, sameOriginQueryFallback: nil),
                    requestReferer: blob.pageURL,
                    document: document,
                    usesCapturedDocument: true,
                    capturedContentID: blob.capturedContentID,
                    widevinePlaybackContext: blobContextIndices[blobIndex]
                        .flatMap { playbackContexts[$0] },
                    pageURL: blob.pageURL,
                    title: limitedTitle(blob.title),
                    thumbnailURL: nil,
                    iframeDepth: blob.iframeDepth,
                    origin: .runtime,
                    accepted: &accepted,
                    results: &results
                )
                WebBlobCaptureStore.discardCaptureFile(at: blob.fileURL)

            case .progressive:
                appendCandidate(
                    kind: .progressive,
                    request: URLCandidates(primary: blob.blobURL, sameOriginQueryFallback: nil),
                    requestReferer: blob.pageURL,
                    document: nil,
                    progressiveMedia: ProgressiveMediaReference(
                        storage: .capturedBlob(
                            fileURL: blob.fileURL,
                            byteCount: blob.byteCount
                        ),
                        hintedMIMEType: blob.mimeType
                    ),
                    capturedContentID: blob.capturedContentID,
                    pageURL: blob.pageURL,
                    title: limitedTitle(blob.title),
                    thumbnailURL: nil,
                    iframeDepth: blob.iframeDepth,
                    origin: .runtime,
                    accepted: &accepted,
                    results: &results
                )
            }
        }
    }

    private func capturedManifestData(_ blob: DynamicBlobReference) -> Data? {
        guard blob.byteCount > 0,
              blob.byteCount <= 1_048_576,
              WebBlobCaptureStore.isManagedCaptureURL(blob.fileURL),
              let values = try? blob.fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize == blob.byteCount else {
            return nil
        }
        return try? Data(contentsOf: blob.fileURL, options: .mappedIfSafe)
    }

    private func capturedManifestText(_ blob: DynamicBlobReference) -> String? {
        guard let data = capturedManifestData(blob) else { return nil }
        return decodeText(data)
    }

    /// Associates observed license traffic with a Widevine MPD conservatively.
    /// A frame token must match exactly. References without a token may use an
    /// exact trusted page/depth match plus event proximity; cross-frame global
    /// fallback is deliberately forbidden. Endpoint URLs are retained in memory, but never written to a
    /// diagnostic message because their query can contain credentials.
    private func widevinePlaybackContexts(
        in inspection: DynamicPageInspection,
        rootURL: URL
    ) -> [Int: WidevinePlaybackContext] {
        let mediaIndices = inspection.media.indices.filter {
            inspection.media[$0].kind == .widevineDASH
        }
        guard !mediaIndices.isEmpty else { return [:] }

        let licenseReferences = inspection.licenseRequests.filter { reference in
            isSafeAutomaticURL(reference.url)
                && isSafeAutomaticURL(reference.pageURL)
                && AutomaticNavigationPolicy.isAllowedFrameNavigation(
                    from: rootURL,
                    to: reference.url
                )
                && AutomaticNavigationPolicy.isAllowedFrameNavigation(
                    from: rootURL,
                    to: reference.pageURL
                )
        }.sorted { lhs, rhs in
            if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
            return canonicalURLKey(lhs.url) < canonicalURLKey(rhs.url)
        }
        guard !licenseReferences.isEmpty else { return [:] }

        var contexts: [Int: WidevinePlaybackContext] = [:]
        var unmatchedMedia = Set(mediaIndices)

        for license in licenseReferences {
            if let frameToken = license.frameToken {
                let tokenMatches = unmatchedMedia.filter {
                    inspection.media[$0].frameToken == frameToken
                }
                guard let mediaIndex = nearestPrecedingMediaIndex(
                    Array(tokenMatches),
                    media: inspection.media,
                    licenseSequence: license.sequence
                ) else {
                    continue
                }
                contexts[mediaIndex] = WidevinePlaybackContext(
                    reference: license,
                    detectedWidevineKeySystem: inspection.detectedWidevineKeySystem
                )
                unmatchedMedia.remove(mediaIndex)
                continue
            }

            let candidates = unmatchedMedia.filter {
                    let media = inspection.media[$0]
                    return media.iframeDepth == license.iframeDepth
                        && canonicalURLKey(media.pageURL) == canonicalURLKey(license.pageURL)
                }

            guard let mediaIndex = nearestPrecedingMediaIndex(
                Array(candidates),
                media: inspection.media,
                licenseSequence: license.sequence
            ) else {
                continue
            }
            contexts[mediaIndex] = WidevinePlaybackContext(
                reference: license,
                detectedWidevineKeySystem: inspection.detectedWidevineKeySystem
            )
            unmatchedMedia.remove(mediaIndex)
        }

        log(
            "widevine",
            "playback context association manifests=\(mediaIndices.count) licenseRequests=\(licenseReferences.count) matched=\(contexts.count) eme=\(inspection.detectedWidevineKeySystem)"
        )
        return contexts
    }

    private func nearestPrecedingMediaIndex(
        _ indices: [Int],
        media: [DynamicMediaReference],
        licenseSequence: Int
    ) -> Int? {
        guard !indices.isEmpty else { return nil }
        let preceding = indices.filter { media[$0].sequence <= licenseSequence }
        if let nearest = preceding.max(by: { lhs, rhs in
            media[lhs].sequence < media[rhs].sequence
        }) {
            let nearestSequence = media[nearest].sequence
            let equallyNear = preceding.filter { media[$0].sequence == nearestSequence }
            return equallyNear.count == 1 ? nearest : nil
        }
        return indices.count == 1 ? indices[0] : nil
    }

    private func loadWidevineDASH(
        _ candidates: URLCandidates,
        referer: URL?,
        rootURL: URL
    ) async throws -> (
        kind: MediaCandidateKind,
        request: URLCandidates,
        document: PlaylistDocument
    ) {
        var lastError: Error = HLSError.invalidPlaylist("Widevine MPEG-DASH MPDを確認できませんでした")
        for candidate in candidates.all {
            do {
                log("widevine", "validate MPD \(DiagnosticPrivacy.urlSummary(candidate))")
                let payload = try await client.fetch(candidate, referer: referer)
                guard AutomaticNavigationPolicy.isAllowedFrameNavigation(
                    from: rootURL,
                    to: payload.effectiveURL
                ) else {
                    throw HLSError.network("MPDのリダイレクト先が安全ポリシーにより拒否されました")
                }
                if let text = decodeText(payload.data), PlaylistParser.isPlaylist(text) {
                    log(
                        "playlist",
                        "MPD-shaped URL contained HLS; reclassified status=\(payload.statusCode) bytes=\(payload.data.count) \(DiagnosticPrivacy.urlSummary(payload.effectiveURL))"
                    )
                    return (
                        .hls,
                        URLCandidates(primary: payload.effectiveURL, sameOriginQueryFallback: nil),
                        PlaylistDocument(
                            text: text,
                            effectiveURL: payload.effectiveURL,
                            referer: referer
                        )
                    )
                }
                let document = try validateWidevineDASHPayload(
                    payload,
                    requestedURL: candidate,
                    referer: referer
                )
                return (
                    .widevineDASH,
                    URLCandidates(primary: payload.effectiveURL, sameOriginQueryFallback: nil),
                    document
                )
            } catch is CancellationError {
                throw HLSError.cancelled
            } catch let error as HLSError {
                if case .cancelled = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Best-effort bounded enrichment for a displayed HLS candidate. The
    /// original observed URL remains authoritative for the later download;
    /// this document is used only to expose master-playlist quality choices.
    private func inspectHLSPlaylist(
        _ candidates: URLCandidates,
        referer: URL?,
        rootURL: URL
    ) async -> PlaylistDocument? {
        var lastError: Error?
        for candidate in candidates.all {
            do {
                let payload = try await client.fetch(
                    candidate,
                    referer: referer,
                    maximumBytes: 8 * 1_024 * 1_024
                )
                guard AutomaticNavigationPolicy.isAllowedFrameNavigation(
                    from: rootURL,
                    to: payload.effectiveURL
                ),
                let text = decodeText(payload.data),
                PlaylistParser.isPlaylist(text) else {
                    continue
                }
                let document = PlaylistDocument(
                    text: text,
                    effectiveURL: payload.effectiveURL,
                    referer: referer
                )
                let optionCount = HLSResolutionCatalog.options(from: document).count
                if optionCount > 1 {
                    log("playlist", "quality metadata accepted resolutions=\(optionCount)")
                }
                return document
            } catch {
                if error is CancellationError { return nil }
                if let hlsError = error as? HLSError, case .cancelled = hlsError { return nil }
                lastError = error
            }
        }
        if let lastError {
            log(
                "playlist",
                "quality metadata unavailable error=\(DiagnosticPrivacy.errorCode(lastError))"
            )
        }
        return nil
    }

    /// A URL suffix or DOM MIME type is only a discovery hint. Every remote
    /// progressive candidate must pass a fresh bounded byte probe before it is
    /// shown, and is probed again after the complete job download.
    private func probeProgressiveMedia(
        _ candidates: URLCandidates,
        referer: URL?,
        rootURL: URL
    ) async throws -> (
        request: URLCandidates,
        effectiveURL: URL,
        mimeType: String?,
        container: MediaContainer,
        resolution: MediaResolution?,
        prefixSHA256: Data,
        prefixByteCount: Int
    ) {
        var lastError: Error = HLSError.invalidMediaPayload(
            stream: "progressive",
            number: 1,
            mimeType: nil,
            byteCount: 0,
            signature: "unrecognized"
        )
        for candidate in candidates.all {
            do {
                let probe = try await client.probeMediaPrefix(
                    candidate,
                    referer: referer
                )
                guard AutomaticNavigationPolicy.isAllowedFrameNavigation(
                    from: rootURL,
                    to: probe.effectiveURL
                ),
                let container = ProgressiveMediaDetector.detect(
                    prefix: probe.prefix,
                    url: probe.effectiveURL,
                    mimeType: probe.mimeType
                ),
                ProgressiveMediaDetector.supportsStandaloneDownload(container) else {
                    throw HLSError.invalidMediaPayload(
                        stream: "progressive",
                        number: 1,
                        mimeType: probe.mimeType,
                        byteCount: probe.prefix.count,
                        signature: MediaPayloadInspector.signature(probe.prefix)
                    )
                }
                log(
                    "progressive",
                    "media accepted container=\(container.rawValue) bytesProbed=\(probe.prefix.count) \(DiagnosticPrivacy.urlSummary(probe.effectiveURL))"
                )
                let resolution = await progressiveResolution(
                    from: probe,
                    originalURL: candidate,
                    referer: referer,
                    rootURL: rootURL,
                    container: container
                )
                return (
                    URLCandidates(
                        primary: candidate,
                        sameOriginQueryFallback: nil
                    ),
                    probe.effectiveURL,
                    probe.mimeType,
                    container,
                    resolution,
                    ProgressiveMediaFingerprint.sha256(probe.prefix),
                    probe.prefix.count
                )
            } catch is CancellationError {
                throw HLSError.cancelled
            } catch let error as HLSError {
                if case .cancelled = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func progressiveResolution(
        from probe: HTTPResourceProbe,
        originalURL: URL,
        referer: URL?,
        rootURL: URL,
        container: MediaContainer
    ) async -> MediaResolution? {
        if let resolution = ProgressiveMediaResolutionProbe.detect(
            prefix: probe.prefix,
            container: container
        ) {
            return resolution
        }
        guard container == .isoBaseMedia,
              let total = probe.totalResourceLength,
              total > Int64(probe.prefix.count) else {
            return nil
        }
        let length = min(total, 1_048_576)
        let offset = total - length
        do {
            let payload = try await client.fetch(
                originalURL,
                referer: referer,
                byteRange: ByteRange(offset: offset, length: length),
                maximumBytes: length
            )
            guard AutomaticNavigationPolicy.isAllowedFrameNavigation(
                from: rootURL,
                to: payload.effectiveURL
            ) else {
                return nil
            }
            let resolution = ProgressiveMediaResolutionProbe.detect(
                prefix: payload.data,
                container: container
            )
            if let resolution {
                log("progressive", "resolution metadata accepted value=\(resolution.id)")
            }
            return resolution
        } catch {
            if error is CancellationError { return nil }
            if let hlsError = error as? HLSError, case .cancelled = hlsError { return nil }
            log(
                "progressive",
                "resolution metadata unavailable error=\(DiagnosticPrivacy.errorCode(error))"
            )
            return nil
        }
    }

    private func validateWidevineDASHPayload(
        _ payload: HTTPPayload,
        requestedURL: URL,
        referer: URL?
    ) throws -> PlaylistDocument {
        guard DASHManifestParser.isMPD(payload.data) else {
            throw HLSError.invalidPlaylist("MPEG-DASH MPDが不正です")
        }
        let manifest = try DASHManifestParser.parse(
            data: payload.data,
            effectiveURL: payload.effectiveURL
        )
        guard manifest.isWidevine else {
            throw HLSError.invalidPlaylist("Widevine ContentProtectionのないMPDには対応していません")
        }
        guard isDownloadableWidevineDomain(requestedURL),
              isDownloadableWidevineDomain(payload.effectiveURL) else {
            log(
                "widevine",
                "Widevine MPD response rejected by download-domain policy redirected=\(payload.effectiveURL != requestedURL) \(DiagnosticPrivacy.urlSummary(payload.effectiveURL))"
            )
            throw HLSError.drmUnsupported("Widevine DASH (許可ドメイン外)")
        }
        guard let text = decodeText(payload.data) else {
            throw HLSError.invalidPlaylist("MPEG-DASH MPDをテキストとして読み取れません")
        }
        log(
            "widevine",
            "MPD accepted status=\(payload.statusCode) bytes=\(payload.data.count) \(DiagnosticPrivacy.urlSummary(payload.effectiveURL))"
        )
        return PlaylistDocument(
            text: text,
            effectiveURL: payload.effectiveURL,
            referer: referer
        )
    }

    private func isDASHPayload(_ payload: HTTPPayload) -> Bool {
        DASHManifestParser.isMPD(payload.data)
    }

    private func appendCandidate(
        kind: MediaCandidateKind,
        request: URLCandidates,
        requestReferer: URL?,
        document: PlaylistDocument?,
        progressiveMedia: ProgressiveMediaReference? = nil,
        mediaGroupID: String? = nil,
        usesCapturedDocument: Bool = false,
        capturedContentID: UUID? = nil,
        widevinePlaybackContext: WidevinePlaybackContext? = nil,
        pageURL: URL,
        title: String?,
        thumbnailURL: URL?,
        iframeDepth: Int,
        origin: HLSCandidateOrigin,
        accepted: inout Set<String>,
        results: inout [HLSCandidate]
    ) {
        let key = candidateKey(
            kind: kind,
            url: request.primary,
            referer: requestReferer ?? pageURL,
            capturedContentID: capturedContentID
        )
        guard accepted.insert(key).inserted else {
            guard let index = results.firstIndex(where: {
                candidateKey(
                    kind: $0.kind,
                    url: $0.request.primary,
                    referer: $0.requestReferer ?? $0.pageURL,
                    capturedContentID: $0.capturedContentID
                ) == key
            }) else { return }
            let existing = results[index]
            results[index] = HLSCandidate(
                id: existing.id,
                kind: existing.kind,
                request: existing.request.sameOriginQueryFallback != nil ? existing.request : request,
                requestReferer: existing.requestReferer ?? requestReferer,
                document: existing.document ?? document,
                progressiveMedia: existing.progressiveMedia ?? progressiveMedia,
                mediaGroupID: existing.mediaGroupID ?? mediaGroupID,
                usesCapturedDocument: existing.usesCapturedDocument || usesCapturedDocument,
                capturedContentID: existing.capturedContentID ?? capturedContentID,
                widevinePlaybackContext: existing.widevinePlaybackContext ?? widevinePlaybackContext,
                pageURL: existing.pageURL,
                title: existing.title ?? title,
                thumbnailURL: existing.thumbnailURL ?? thumbnailURL,
                iframeDepth: min(existing.iframeDepth, iframeDepth),
                origin: existing.origin
            )
            log(
                "candidate",
                "merged origin=\(origin.rawValue) depth=\(iframeDepth) thumbnail=\(thumbnailURL != nil) \(DiagnosticPrivacy.urlSummary(document?.effectiveURL ?? request.primary))"
            )
            return
        }
        results.append(
            HLSCandidate(
                id: UUID(),
                kind: kind,
                request: request,
                requestReferer: requestReferer,
                document: document,
                progressiveMedia: progressiveMedia,
                mediaGroupID: mediaGroupID,
                usesCapturedDocument: usesCapturedDocument,
                capturedContentID: capturedContentID,
                widevinePlaybackContext: widevinePlaybackContext,
                pageURL: pageURL,
                title: title,
                thumbnailURL: thumbnailURL,
                iframeDepth: iframeDepth,
                origin: origin
            )
        )
        log(
            "candidate",
            "added origin=\(origin.rawValue) kind=\(kind.rawValue) depth=\(iframeDepth) thumbnail=\(thumbnailURL != nil) \(DiagnosticPrivacy.urlSummary(document?.effectiveURL ?? request.primary))"
        )
    }

    private func log(_ category: String, _ message: String) {
        diagnosticSink?(DiagnosticEvent(category: category, message: message))
    }

    private func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private func resolvedAutomaticURL(_ rawValue: String?, relativeTo baseURL: URL) -> URL? {
        guard let rawValue,
              let url = try? URIResolver.resolveURL(rawValue, relativeTo: baseURL),
              isSafeAutomaticURL(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.fragment = nil
        return components.url
    }

    private func isSafeAutomaticURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            return false
        }
        return true
    }

    private func canonicalURLKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string ?? url.absoluteString
    }

    private func candidateKey(
        kind: MediaCandidateKind,
        url: URL,
        referer: URL?,
        capturedContentID: UUID? = nil
    ) -> String {
        if let capturedContentID {
            return kind.rawValue + "\ncapture:" + capturedContentID.uuidString.lowercased()
        }
        return kind.rawValue + "\n" + canonicalURLKey(url) + "\n" + (referer.map(canonicalURLKey) ?? "")
    }

    private func limitedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(160))
    }
}

enum AutomaticNavigationPolicy {
    static func isAllowedFrameNavigation(from rootURL: URL, to targetURL: URL) -> Bool {
        !isPrivateOrLocal(targetURL) || isPrivateOrLocal(rootURL)
    }

    static func isAllowedNativeFrameNavigation(from rootURL: URL, to targetURL: URL) -> Bool {
        guard isAllowedFrameNavigation(from: rootURL, to: targetURL) else { return false }
        return isPrivateOrLocal(rootURL) || isSameOrigin(rootURL, targetURL)
    }

    static func isPrivateOrLocal(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return true }
        host = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty else { return true }

        let localNames = [
            "localhost", ".localhost", ".local", ".lan", ".internal",
            ".home", ".home.arpa", ".localdomain"
        ]
        if localNames.contains(where: { host == $0 || host.hasSuffix($0) }) {
            return true
        }

        if host.contains(":") {
            if host == "::" || host == "::1" || host.hasPrefix("fe8")
                || host.hasPrefix("fe9") || host.hasPrefix("fea")
                || host.hasPrefix("feb") || host.hasPrefix("fc")
                || host.hasPrefix("fd") || host.hasPrefix("ff") {
                return true
            }
            if let mapped = host.split(separator: ":").last,
               mapped.contains(".") {
                return isPrivateIPv4(String(mapped))
            }
            if host.hasPrefix("::ffff:") {
                let groups = host.dropFirst("::ffff:".count).split(separator: ":")
                if groups.count == 2,
                   let high = UInt32(groups[0], radix: 16), high <= 0xFFFF,
                   let low = UInt32(groups[1], radix: 16), low <= 0xFFFF {
                    return isPrivateIPv4((high << 16) | low)
                }
            }
            return false
        }

        if host.hasPrefix("0x"), let value = UInt32(host.dropFirst(2), radix: 16) {
            return isPrivateIPv4(value)
        }
        if host.allSatisfy({ $0.isNumber }), let value = UInt32(host) {
            return isPrivateIPv4(value)
        }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            return isPrivateIPv4(host)
        }
        if !host.contains(".") {
            return true
        }
        return false
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ !$0.isEmpty && !($0.count > 1 && $0.first == "0") }),
              let first = UInt8(parts[0]),
              let second = UInt8(parts[1]),
              UInt8(parts[2]) != nil,
              UInt8(parts[3]) != nil else {
            return true
        }
        return isPrivateIPv4(first: first, second: second)
    }

    private static func isPrivateIPv4(_ value: UInt32) -> Bool {
        isPrivateIPv4(
            first: UInt8((value >> 24) & 0xFF),
            second: UInt8((value >> 16) & 0xFF)
        )
    }

    private static func isPrivateIPv4(first: UInt8, second: UInt8) -> Bool {
        switch (first, second) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168):
            return true
        case (100, 64...127), (172, 16...31), (198, 18...19):
            return true
        case (192, 0), (192, 2), (198, 51), (203, 0):
            return true
        default:
            return first >= 224
        }
    }

    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
