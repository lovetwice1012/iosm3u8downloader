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
    private let maximumHTMLBytes = 8 * 1_024 * 1_024
    private let maximumDocuments = 16
    private let maximumIframeDepth = 3
    private let maximumFramesPerDocument = 12
    private let maximumCandidateReferences = 128
    private let maximumResults = 64

    init(client: HTTPClient, dynamicInspector: (any DynamicPageInspecting)? = nil) {
        self.client = client
        self.dynamicInspector = dynamicInspector
    }

    func discover(input: String) async throws -> HLSDiscoveryResult {
        let inputURL = try URIResolver.normalizeInput(input)
        let payload: HTTPPayload
        do {
            payload = try await client.fetch(inputURL)
        } catch {
            if error is CancellationError { throw HLSError.cancelled }
            if let hlsError = error as? HLSError, case .cancelled = hlsError {
                throw hlsError
            }
            let originalError = error
            let candidates = try await dynamicallyDiscoveredCandidates(rootURL: inputURL)
            if !candidates.isEmpty {
                return HLSDiscoveryResult(candidates: candidates, isDirectPlaylist: false)
            }
            throw originalError
        }
        guard AutomaticNavigationPolicy.isAllowedFrameNavigation(
            from: inputURL,
            to: payload.effectiveURL
        ) else {
            throw HLSError.network("公開URLからローカルネットワークへのリダイレクトを拒否しました")
        }
        guard let text = decodeText(payload.data) else {
            let candidates = try await dynamicallyDiscoveredCandidates(rootURL: payload.effectiveURL)
            guard !candidates.isEmpty else { throw HLSError.noPlaylistFound }
            return HLSDiscoveryResult(candidates: candidates, isDirectPlaylist: false)
        }

        if PlaylistParser.isPlaylist(text) {
            let document = PlaylistDocument(
                text: text,
                effectiveURL: payload.effectiveURL,
                referer: inputURL
            )
            return HLSDiscoveryResult(
                candidates: [
                    HLSCandidate(
                        id: UUID(),
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
            let candidates = try await dynamicallyDiscoveredCandidates(rootURL: payload.effectiveURL)
            guard !candidates.isEmpty else { throw HLSError.htmlTooLarge }
            return HLSDiscoveryResult(candidates: candidates, isDirectPlaylist: false)
        }
        let candidates = try await discoverInHTML(
            rootHTML: text,
            rootURL: payload.effectiveURL,
            rootReferer: inputURL
        )
        guard !candidates.isEmpty else { throw HLSError.noPlaylistFound }
        return HLSDiscoveryResult(candidates: candidates, isDirectPlaylist: false)
    }

    func resolve(input: String) async throws -> PlaylistDocument {
        let discovery = try await discover(input: input)
        guard let first = discovery.candidates.first else { throw HLSError.noPlaylistFound }
        if let document = first.document { return document }
        return try await load(first.request, referer: first.requestReferer)
    }

    func load(_ candidates: URLCandidates, referer: URL?) async throws -> PlaylistDocument {
        var lastError: Error = HLSError.invalidPlaylist("リンク先がm3u8ではありません")
        for candidate in candidates.all {
            do {
                let payload = try await client.fetch(candidate, referer: referer)
                guard let text = decodeText(payload.data), PlaylistParser.isPlaylist(text) else {
                    throw HLSError.invalidPlaylist("リンク先がm3u8ではありません")
                }
                return PlaylistDocument(text: text, effectiveURL: payload.effectiveURL, referer: referer)
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

    private func discoverInHTML(
        rootHTML: String,
        rootURL: URL,
        rootReferer: URL?
    ) async throws -> [HLSCandidate] {
        async let dynamicInspection = inspectDynamically(rootURL)

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
                    let payload = try await client.fetch(requestedURL, referer: work.referer)
                    guard AutomaticNavigationPolicy.isAllowedNativeFrameNavigation(
                        from: rootURL,
                        to: payload.effectiveURL
                    ) else { continue }
                    let effectiveKey = canonicalURLKey(payload.effectiveURL)
                    if effectiveKey != requestedKey,
                       !visitedRemoteDocuments.insert(effectiveKey).inserted {
                        continue
                    }
                    guard let fetchedText = decodeText(payload.data) else { continue }
                    if PlaylistParser.isPlaylist(fetchedText) {
                        let document = PlaylistDocument(
                            text: fetchedText,
                            effectiveURL: payload.effectiveURL,
                            referer: work.referer
                        )
                        appendCandidate(
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
                    guard payload.data.count <= maximumHTMLBytes else { continue }
                    html = fetchedText
                    documentURL = payload.effectiveURL
                } catch is CancellationError {
                    throw HLSError.cancelled
                } catch let error as HLSError {
                    if case .cancelled = error { throw error }
                    continue
                } catch {
                    continue
                }
            }

            let extraction = HTMLMediaExtractor.extract(from: html)
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
                let attemptKey = candidateKey(url: request.primary, referer: documentURL)
                _ = discoveredCandidates.insert(attemptKey)

                let resolvedThumbnailURL = resolvedAutomaticURL(
                    reference.rawPosterURL,
                    relativeTo: documentBaseURL
                ) ?? pageThumbnailURL
                let thumbnailURL = resolvedThumbnailURL.flatMap {
                    AutomaticNavigationPolicy.isAllowedFrameNavigation(from: rootURL, to: $0) ? $0 : nil
                }
                appendCandidate(
                    request: request,
                    requestReferer: documentURL,
                    document: nil,
                    pageURL: documentURL,
                    title: limitedTitle(reference.title ?? pageTitle),
                    thumbnailURL: thumbnailURL,
                    iframeDepth: work.iframeDepth,
                    origin: reference.origin,
                    accepted: &acceptedCandidates,
                    results: &results
                )
            }

            guard work.iframeDepth < maximumIframeDepth else { continue }
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
                ), AutomaticNavigationPolicy.isAllowedNativeFrameNavigation(
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
                }
            }
        }

        let dynamic = await dynamicInspection
        try Task.checkCancellation()
        client.storeCookies(dynamic.cookies)

        appendDynamicCandidates(
            dynamic,
            rootURL: rootURL,
            discovered: &discoveredCandidates,
            accepted: &acceptedCandidates,
            results: &results
        )

        return results
    }

    private func inspectDynamically(_ url: URL) async -> DynamicPageInspection {
        guard let dynamicInspector else { return .empty }
        return await dynamicInspector.inspect(url: url, seedCookies: client.cookies(for: url))
    }

    private func dynamicallyDiscoveredCandidates(rootURL: URL) async throws -> [HLSCandidate] {
        let dynamic = await inspectDynamically(rootURL)
        try Task.checkCancellation()
        client.storeCookies(dynamic.cookies)
        var discovered = Set<String>()
        var accepted = Set<String>()
        var results: [HLSCandidate] = []
        appendDynamicCandidates(
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
    ) {
        for reference in inspection.media where results.count < maximumResults {
            guard discovered.count < maximumCandidateReferences else { break }
            guard isSafeAutomaticURL(reference.url) else { continue }
            let pageURL = isSafeAutomaticURL(reference.pageURL) ? reference.pageURL : rootURL
            let attemptKey = candidateKey(url: reference.url, referer: pageURL)
            _ = discovered.insert(attemptKey)

            appendCandidate(
                request: URLCandidates(primary: reference.url, sameOriginQueryFallback: nil),
                requestReferer: pageURL,
                document: nil,
                pageURL: pageURL,
                title: limitedTitle(reference.title),
                thumbnailURL: reference.thumbnailURL.flatMap {
                    isSafeAutomaticURL($0)
                        && AutomaticNavigationPolicy.isAllowedFrameNavigation(from: rootURL, to: $0)
                        ? $0 : nil
                },
                iframeDepth: reference.iframeDepth,
                origin: reference.origin,
                accepted: &accepted,
                results: &results
            )
        }
    }

    private func appendCandidate(
        request: URLCandidates,
        requestReferer: URL?,
        document: PlaylistDocument?,
        pageURL: URL,
        title: String?,
        thumbnailURL: URL?,
        iframeDepth: Int,
        origin: HLSCandidateOrigin,
        accepted: inout Set<String>,
        results: inout [HLSCandidate]
    ) {
        let key = candidateKey(
            url: document?.effectiveURL ?? request.primary,
            referer: document?.referer ?? requestReferer ?? pageURL
        )
        guard accepted.insert(key).inserted else {
            guard let index = results.firstIndex(where: {
                candidateKey(
                    url: $0.document?.effectiveURL ?? $0.request.primary,
                    referer: $0.document?.referer ?? $0.requestReferer ?? $0.pageURL
                ) == key
            }) else { return }
            let existing = results[index]
            results[index] = HLSCandidate(
                id: existing.id,
                request: existing.request.sameOriginQueryFallback != nil ? existing.request : request,
                requestReferer: existing.requestReferer ?? requestReferer,
                document: existing.document ?? document,
                pageURL: existing.pageURL,
                title: existing.title ?? title,
                thumbnailURL: existing.thumbnailURL ?? thumbnailURL,
                iframeDepth: min(existing.iframeDepth, iframeDepth),
                origin: existing.origin
            )
            return
        }
        results.append(
            HLSCandidate(
                id: UUID(),
                request: request,
                requestReferer: requestReferer,
                document: document,
                pageURL: pageURL,
                title: title,
                thumbnailURL: thumbnailURL,
                iframeDepth: iframeDepth,
                origin: origin
            )
        )
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

    private func candidateKey(url: URL, referer: URL?) -> String {
        canonicalURLKey(url) + "\n" + (referer.map(canonicalURLKey) ?? "")
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
