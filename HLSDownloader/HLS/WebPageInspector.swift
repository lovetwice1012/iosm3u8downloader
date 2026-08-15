import Combine
import Foundation
import WebKit

struct DynamicMediaReference: Sendable {
    let url: URL
    let kind: MediaCandidateKind
    let pageURL: URL
    let title: String?
    let thumbnailURL: URL?
    let iframeDepth: Int
    let origin: HLSCandidateOrigin
    let frameToken: String?
    let sequence: Int

    init(
        url: URL,
        kind: MediaCandidateKind,
        pageURL: URL,
        title: String?,
        thumbnailURL: URL?,
        iframeDepth: Int,
        origin: HLSCandidateOrigin,
        frameToken: String? = nil,
        sequence: Int = 0
    ) {
        self.url = url
        self.kind = kind
        self.pageURL = pageURL
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.iframeDepth = max(iframeDepth, 0)
        self.origin = origin
        self.frameToken = PlaybackProbePayloadParser.normalizedFrameToken(frameToken)
        self.sequence = max(sequence, 0)
    }
}

struct DynamicPageInspection: @unchecked Sendable {
    let media: [DynamicMediaReference]
    let cookies: [HTTPCookie]
    let licenseRequests: [DynamicLicenseReference]
    let detectedWidevineKeySystem: Bool

    init(
        media: [DynamicMediaReference],
        cookies: [HTTPCookie],
        licenseRequests: [DynamicLicenseReference] = [],
        detectedWidevineKeySystem: Bool = false
    ) {
        self.media = media
        self.cookies = cookies
        self.licenseRequests = licenseRequests
        self.detectedWidevineKeySystem = detectedWidevineKeySystem
    }

    static let empty = DynamicPageInspection(media: [], cookies: [])
}

struct PlaybackLicenseProbePayload {
    let rawURL: String
    let metadata: WidevineLicenseRequestMetadata
    let frameToken: String?
    let sequence: Int
}

enum PlaybackProbePayloadParser {
    private static let maximumURLLength = 8_192
    private static let maximumFrameTokenLength = 64
    private static let maximumHeaderNames = 32

    static func hasValidNonce(_ body: [String: Any], expected: String) -> Bool {
        guard let candidate = body["nonce"] as? String else { return false }
        let candidateBytes = Array(candidate.utf8)
        let expectedBytes = Array(expected.utf8)
        guard candidateBytes.count == expectedBytes.count,
              !expectedBytes.isEmpty,
              expectedBytes.count <= 64 else {
            return false
        }
        var difference: UInt8 = 0
        for index in expectedBytes.indices {
            difference |= candidateBytes[index] ^ expectedBytes[index]
        }
        return difference == 0
    }

    static func licensePayload(from body: [String: Any]) -> PlaybackLicenseProbePayload? {
        guard (body["eventKind"] as? String) == "licenseRequest",
              let rawURL = body["url"] as? String,
              !rawURL.isEmpty,
              rawURL.utf8.count <= maximumURLLength,
              let rawBodyKind = body["bodyKind"] as? String,
              let bodyKind = WidevineLicenseRequestMetadata.BodyKind(rawValue: rawBodyKind),
              let rawSource = body["source"] as? String,
              let source = WidevineLicenseRequestMetadata.Source(rawValue: rawSource) else {
            return nil
        }

        let rawHeaderNames = (body["headerNames"] as? [String]) ?? []
        guard rawHeaderNames.count <= maximumHeaderNames else { return nil }
        let bodyByteCount = (body["bodyByteCount"] as? NSNumber)?.intValue ?? 0
        let sequence = (body["sequence"] as? NSNumber)?.intValue ?? 0
        let metadata = WidevineLicenseRequestMetadata(
            method: (body["method"] as? String) ?? "UNKNOWN",
            contentType: body["contentType"] as? String,
            headerNames: rawHeaderNames,
            bodyKind: bodyKind,
            bodyByteCount: bodyByteCount,
            source: source
        )
        return PlaybackLicenseProbePayload(
            rawURL: rawURL,
            metadata: metadata,
            frameToken: normalizedFrameToken(body["frameToken"] as? String),
            sequence: max(sequence, 0)
        )
    }

    static func normalizedFrameToken(_ value: String?) -> String? {
        guard let value else { return nil }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              token.count <= maximumFrameTokenLength,
              token.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
                      .contains(scalar)
              }) else {
            return nil
        }
        return token
    }
}

@MainActor
protocol DynamicPageInspecting: AnyObject, Sendable {
    func inspect(url: URL, seedCookies: [HTTPCookie]) async -> DynamicPageInspection
}

@MainActor
final class WebPageInspector: DynamicPageInspecting {
    private let diagnosticSink: DiagnosticSink?

    init(diagnosticSink: DiagnosticSink? = nil) {
        self.diagnosticSink = diagnosticSink
    }

    func inspect(url: URL, seedCookies: [HTTPCookie]) async -> DynamicPageInspection {
        diagnosticSink?(
            DiagnosticEvent(
                category: "webkit",
                message: "session start seedCookies=\(seedCookies.count) \(DiagnosticPrivacy.urlSummary(url))"
            )
        )
        let session = WebPageInspectionSession(
            url: url,
            seedCookies: seedCookies,
            diagnosticSink: diagnosticSink
        )
        return await session.run()
    }
}

@MainActor
private final class WebPageInspectionSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private enum FinishReason: String {
        case settled
        case navigationFailed
        case provisionalNavigationFailed
        case webProcessTerminated
        case hardTimeout
        case cancelled

        var priority: Int {
            switch self {
            case .settled: return 0
            case .navigationFailed, .provisionalNavigationFailed: return 1
            case .webProcessTerminated: return 2
            case .hardTimeout: return 3
            case .cancelled: return 4
            }
        }
    }

    private static let messageName = "hlsDiscovery"
    private static let maximumMessages = 512
    private static let maximumRawMessages = 4_096
    private static let maximumURLLength = 8_192
    private static let maximumLoggedReferences = 64
    private static let maximumLicenseRequests = 128

    private let rootURL: URL
    private let seedCookies: [HTTPCookie]
    private let diagnosticSink: DiagnosticSink?
    private let messageNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let websiteDataStore = WKWebsiteDataStore.nonPersistent()
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<DynamicPageInspection, Never>?
    private var hardTimeoutTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var navigationFinished = false
    private var finishRequested = false
    private var isFinishing = false
    private var messageCount = 0
    private var rawMessageCount = 0
    private var invalidMessageCount = 0
    private var duplicateReferenceCount = 0
    private var blockedNavigationCount = 0
    private var referenceLimitReached = false
    private var rawMessageLimitReached = false
    private var loggedReferenceCount = 0
    private var referenceLogLimitReported = false
    private var references: [String: DynamicMediaReference] = [:]
    private var referenceOrder: [String] = []
    private var licenseRequests: [DynamicLicenseReference] = []
    private var licenseRequestKeys = Set<String>()
    private var detectedWidevineKeySystem = false
    private var navigationContexts: [String: (pageURL: URL, iframeDepth: Int)] = [:]
    private var pendingFinishReason: FinishReason = .settled

    init(url: URL, seedCookies: [HTTPCookie], diagnosticSink: DiagnosticSink?) {
        rootURL = url
        self.seedCookies = seedCookies
        self.diagnosticSink = diagnosticSink
    }

    func run() async -> DynamicPageInspection {
        await seedCookieStore()

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                startWebView()
                if Task.isCancelled || finishRequested {
                    Task { @MainActor [weak self] in
                        await self?.finish(reason: .cancelled)
                    }
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.finishRequested = true
                await self?.finish(reason: .cancelled)
            }
        })
    }

    private func startWebView() {
        guard !isFinishing else { return }
        let contentController = WKUserContentController()
        contentController.add(
            self,
            contentWorld: .page,
            name: Self.messageName
        )
        contentController.addUserScript(
            WKUserScript(
                source: Self.probeJavaScript(
                    interactive: false,
                    messageNonce: messageNonce
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page
            )
        )

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = websiteDataStore
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.applicationNameForUserAgent = "HLSDownloader/1.0"
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        webView.customUserAgent = HTTPClient.userAgent
        webView.navigationDelegate = self
        self.webView = webView
        webView.load(URLRequest(url: rootURL, cachePolicy: .reloadIgnoringLocalCacheData))

        hardTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.finish(reason: .hardTimeout)
        }
    }

    private func seedCookieStore() async {
        for cookie in seedCookies {
            await withCheckedContinuation { continuation in
                websiteDataStore.httpCookieStore.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            websiteDataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
    }

    private func scheduleSettle(
        after nanoseconds: UInt64 = 6_000_000_000,
        reason: FinishReason = .settled
    ) {
        guard navigationFinished, !isFinishing else { return }
        if reason.priority > pendingFinishReason.priority {
            pendingFinishReason = reason
        }
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            await self.finish(reason: self.pendingFinishReason)
        }
    }

    private func finish(reason: FinishReason) async {
        guard !isFinishing, let continuation else {
            finishRequested = true
            return
        }
        isFinishing = true
        hardTimeoutTask?.cancel()
        settleTask?.cancel()
        hardTimeoutTask = nil
        settleTask = nil

        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: Self.messageName,
                contentWorld: .page
            )
            webView.configuration.userContentController.removeAllUserScripts()
        }
        webView = nil

        let cookies = await allCookies()
        let media = referenceOrder.compactMap { references[$0] }
        log(
            "finish reason=\(reason.rawValue) rawMessages=\(rawMessageCount) invalid=\(invalidMessageCount) duplicates=\(duplicateReferenceCount) accepted=\(media.count) licenseMetadata=\(licenseRequests.count) widevineEME=\(detectedWidevineKeySystem) blockedNavigations=\(blockedNavigationCount) rawLimit=\(rawMessageLimitReached) referenceLimit=\(referenceLimitReached) cookies=\(cookies.count)"
        )
        self.continuation = nil
        continuation.resume(
            returning: DynamicPageInspection(
                media: media,
                cookies: cookies,
                licenseRequests: licenseRequests,
                detectedWidevineKeySystem: detectedWidevineKeySystem
            )
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationFinished = true
        log("navigation finished")
        scheduleSettle(after: 6_000_000_000)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationFinished = true
        log("navigation failed error=\(DiagnosticPrivacy.errorCode(error))")
        scheduleSettle(after: 750_000_000, reason: .navigationFailed)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationFinished = true
        log("provisional navigation failed error=\(DiagnosticPrivacy.errorCode(error))")
        scheduleSettle(after: 750_000_000, reason: .provisionalNavigationFailed)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationFinished = true
        log("web content process terminated")
        scheduleSettle(after: 100_000_000, reason: .webProcessTerminated)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame != nil else {
            blockedNavigationCount += 1
            decisionHandler(.cancel)
            return
        }
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        if scheme == "about" {
            decisionHandler(.allow)
        } else if let targetURL = navigationAction.request.url,
                  (scheme == "http" || scheme == "https"),
                  AutomaticNavigationPolicy.isAllowedFrameNavigation(
                    from: rootURL,
                    to: targetURL
                  ) {
            let navigationContext = (
                pageURL: trustedFrameURL(from: navigationAction.sourceFrame) ?? rootURL,
                iframeDepth: navigationAction.targetFrame?.isMainFrame == true ? 0 : 1
            )
            navigationContexts[canonicalKey(targetURL)] = navigationContext
            if let kind = manifestKind(for: targetURL) {
                recordReference(
                    url: targetURL,
                    kind: kind,
                    pageURL: navigationContext.pageURL,
                    title: nil,
                    thumbnailURL: nil,
                    iframeDepth: navigationContext.iframeDepth,
                    origin: .iframe
                )
            }
            decisionHandler(.allow)
        } else {
            blockedNavigationCount += 1
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard let targetURL = navigationResponse.response.url else {
            blockedNavigationCount += 1
            decisionHandler(.cancel)
            return
        }
        if targetURL.scheme?.lowercased() == "about" {
            decisionHandler(.allow)
            return
        }
        guard
              AutomaticNavigationPolicy.isAllowedFrameNavigation(
                from: rootURL,
                to: targetURL
              ) else {
            blockedNavigationCount += 1
            decisionHandler(.cancel)
            return
        }
        if let kind = manifestKind(forMIMEType: navigationResponse.response.mimeType) {
            let context = navigationContexts[canonicalKey(targetURL)]
            recordReference(
                url: targetURL,
                kind: kind,
                pageURL: context?.pageURL ?? rootURL,
                title: nil,
                thumbnailURL: nil,
                iframeDepth: context?.iframeDepth ?? (navigationResponse.isForMainFrame ? 0 : 1),
                origin: .iframe
            )
        }
        decisionHandler(.allow)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageName else {
            return
        }
        guard rawMessageCount < Self.maximumRawMessages else {
            rawMessageLimitReached = true
            return
        }
        rawMessageCount += 1
        guard let body = message.body as? [String: Any],
              PlaybackProbePayloadParser.hasValidNonce(body, expected: messageNonce) else {
            invalidMessageCount += 1
            return
        }
        if receiveWidevineProbeEvent(body, message: message) {
            return
        }
        guard
              let rawURL = body["url"] as? String,
              let rawManifestKind = body["manifestKind"] as? String,
              let kind = MediaCandidateKind(rawValue: rawManifestKind),
              rawURL.utf8.count <= Self.maximumURLLength else {
            invalidMessageCount += 1
            return
        }

        let frameURL = trustedFrameURL(from: message.frameInfo) ?? rootURL
        guard let url = resolvedWebURL(rawURL, relativeTo: frameURL) else {
            invalidMessageCount += 1
            return
        }
        let thumbnailURL: URL?
        if let rawPoster = body["poster"] as? String,
           rawPoster.utf8.count <= Self.maximumURLLength {
            thumbnailURL = resolvedWebURL(rawPoster, relativeTo: frameURL)
        } else {
            thumbnailURL = nil
        }
        let title = limitedText(body["title"] as? String, maximumLength: 256)
        let origin: HLSCandidateOrigin
        switch (body["kind"] as? String)?.lowercased() {
        case "video": origin = .video
        case "source": origin = .source
        case "script": origin = .inlineScript
        default: origin = .runtime
        }

        recordReference(
            url: url,
            kind: kind,
            pageURL: frameURL,
            title: title,
            thumbnailURL: thumbnailURL,
            iframeDepth: message.frameInfo.isMainFrame ? 0 : 1,
            origin: origin,
            frameToken: PlaybackProbePayloadParser.normalizedFrameToken(body["frameToken"] as? String),
            sequence: (body["sequence"] as? NSNumber)?.intValue ?? 0
        )
    }

    private func receiveWidevineProbeEvent(
        _ body: [String: Any],
        message: WKScriptMessage
    ) -> Bool {
        switch body["eventKind"] as? String {
        case "widevineEME":
            if !detectedWidevineKeySystem {
                detectedWidevineKeySystem = true
                log("Widevine EME key-system request observed")
            }
            scheduleSettle()
            return true
        case "licenseRequest":
            guard let payload = PlaybackProbePayloadParser.licensePayload(from: body) else {
                invalidMessageCount += 1
                return true
            }
            guard let frameURL = trustedFrameURL(from: message.frameInfo),
                  let url = resolvedWebURL(payload.rawURL, relativeTo: frameURL),
                  AutomaticNavigationPolicy.isAllowedFrameNavigation(from: rootURL, to: url) else {
                invalidMessageCount += 1
                return true
            }
            let depth = message.frameInfo.isMainFrame ? 0 : 1
            let key = canonicalKey(url)
                + "\n" + canonicalKey(frameURL)
                + "\n" + (payload.frameToken ?? "")
                + "\n" + payload.metadata.method
                + "\n" + payload.metadata.source.rawValue
            guard licenseRequestKeys.insert(key).inserted else { return true }
            guard licenseRequests.count < Self.maximumLicenseRequests else {
                referenceLimitReached = true
                return true
            }
            licenseRequests.append(
                DynamicLicenseReference(
                    url: url,
                    pageURL: frameURL,
                    iframeDepth: depth,
                    frameToken: payload.frameToken,
                    metadata: payload.metadata,
                    sequence: payload.sequence
                )
            )
            log(
                "license request metadata observed source=\(payload.metadata.source.rawValue) method=\(payload.metadata.method) headers=\(payload.metadata.headerNames.count) body=\(payload.metadata.bodyKind.rawValue)"
            )
            scheduleSettle()
            return true
        default:
            return false
        }
    }

    private func recordReference(
        url: URL,
        kind: MediaCandidateKind,
        pageURL: URL,
        title: String?,
        thumbnailURL: URL?,
        iframeDepth: Int,
        origin: HLSCandidateOrigin,
        frameToken: String? = nil,
        sequence: Int = 0
    ) {
        let key = kind.rawValue
            + "\n" + canonicalKey(url)
            + "\n" + canonicalKey(pageURL)
            + "\n" + (frameToken ?? "")
        var didChange = false
        if let existing = references[key] {
            duplicateReferenceCount += 1
            if existing.title == nil && title != nil
                || existing.thumbnailURL == nil && thumbnailURL != nil
                || existing.frameToken == nil && frameToken != nil
                || existing.sequence == 0 && sequence > 0 {
                references[key] = DynamicMediaReference(
                    url: existing.url,
                    kind: existing.kind,
                    pageURL: existing.pageURL,
                    title: existing.title ?? title,
                    thumbnailURL: existing.thumbnailURL ?? thumbnailURL,
                    iframeDepth: existing.iframeDepth,
                    origin: existing.origin,
                    frameToken: existing.frameToken ?? frameToken,
                    sequence: existing.sequence > 0 ? existing.sequence : sequence
                )
                didChange = true
            }
        } else {
            guard messageCount < Self.maximumMessages else {
                referenceLimitReached = true
                return
            }
            messageCount += 1
            references[key] = DynamicMediaReference(
                url: url,
                kind: kind,
                pageURL: pageURL,
                title: title,
                thumbnailURL: thumbnailURL,
                iframeDepth: iframeDepth,
                origin: origin,
                frameToken: frameToken,
                sequence: sequence
            )
            referenceOrder.append(key)
            if loggedReferenceCount < Self.maximumLoggedReferences {
                loggedReferenceCount += 1
                log(
                    "reference added kind=\(kind.rawValue) origin=\(origin.rawValue) depth=\(iframeDepth) thumbnail=\(thumbnailURL != nil) \(DiagnosticPrivacy.urlSummary(url))"
                )
            } else if !referenceLogLimitReported {
                referenceLogLimitReported = true
                log("reference detail log limit reached limit=\(Self.maximumLoggedReferences)")
            }
            didChange = true
        }
        if didChange { scheduleSettle() }
    }

    private func manifestKind(forMIMEType mimeType: String?) -> MediaCandidateKind? {
        guard let mimeType = mimeType?.lowercased() else { return nil }
        if mimeType.contains("application/dash+xml") { return .widevineDASH }
        if mimeType.contains("application/vnd.apple.mpegurl")
            || mimeType.contains("application/x-mpegurl")
            || mimeType.contains("application/mpegurl")
            || mimeType.contains("audio/mpegurl")
            || mimeType.contains("audio/x-mpegurl") {
            return .hls
        }
        return nil
    }

    private func manifestKind(for url: URL) -> MediaCandidateKind? {
        switch url.pathExtension.lowercased() {
        case "m3u8": return .hls
        case "mpd": return .widevineDASH
        default: return nil
        }
    }

    private func trustedFrameURL(from frameInfo: WKFrameInfo) -> URL? {
        guard let url = frameInfo.request.url else { return nil }
        return resolvedWebURL(url.absoluteString, relativeTo: rootURL)
    }

    private func resolvedWebURL(_ rawValue: String, relativeTo baseURL: URL) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil,
              url.user == nil,
              url.password == nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.fragment = nil
        return components.url
    }

    private func canonicalKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    private func limitedText(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumLength))
    }

    private func log(_ message: String) {
        diagnosticSink?(DiagnosticEvent(category: "webkit", message: message))
    }

    fileprivate static func probeJavaScript(
        interactive: Bool,
        messageNonce: String
    ) -> String {
        probeJavaScriptTemplate
            .replacingOccurrences(
                of: "__HLS_DOWNLOADER_INTERACTIVE__",
                with: interactive ? "true" : "false"
            )
            .replacingOccurrences(
                of: "__HLS_DOWNLOADER_MESSAGE_NONCE__",
                with: messageNonce
            )
    }

    private static let probeJavaScriptTemplate = #"""
    (() => {
      if (window.__hlsDownloaderProbeInstalled) return;
      window.__hlsDownloaderProbeInstalled = true;
      const interactive = __HLS_DOWNLOADER_INTERACTIVE__;
      const probeNonce = '__HLS_DOWNLOADER_MESSAGE_NONCE__';
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hlsDiscovery;
      if (!handler) return;
      const frameToken = (() => {
        try {
          if (self.crypto && typeof self.crypto.randomUUID === 'function') {
            return self.crypto.randomUUID();
          }
          if (self.crypto && typeof self.crypto.getRandomValues === 'function') {
            const bytes = new Uint8Array(16);
            self.crypto.getRandomValues(bytes);
            return Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
          }
        } catch (_) {}
        return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 18)}`.slice(0, 64);
      })();
      let observationSequence = 0;
      const nextSequence = () => {
        observationSequence = observationSequence >= 2147483646 ? 1 : observationSequence + 1;
        return observationSequence;
      };
      const posted = new Map();
      const postedLicenseRequests = new Set();
      const maximumPostedEntries = 2048;
      const maximumPostedLicenseRequests = 256;
      const maximumBodyBytes = 64 * 1024;
      const maximumInspectableContentLength = 1024 * 1024;
      let widevineManifestObserved = false;
      let widevineKeySystemRequested = false;
      let widevineEMEPosted = false;
      let emeMessageSignalUntil = 0;
      let emeMessageBytes = null;
      let emeMessageBase64 = '';
      const hlsType = value => /(?:application|audio)\/(?:vnd\.apple\.mpegurl|x-mpegurl|mpegurl)/i.test(value || '');
      const dashType = value => /application\/dash\+xml/i.test(value || '');
      const typeKind = value => dashType(value) ? 'widevineDASH' : (hlsType(value) ? 'hls' : '');
      const decode = value => String(value == null ? '' : value)
        .replace(/\\\//g, '/')
        .replace(/\\u002f/gi, '/')
        .replace(/\\u002e/gi, '.')
        .replace(/\\u003a/gi, ':')
        .replace(/\\u003f/gi, '?')
        .replace(/\\u003d/gi, '=')
        .replace(/\\u0026/gi, '&')
        .replace(/\\x2f/gi, '/')
        .replace(/\\x2e/gi, '.');
      const absolute = (value, baseURL) => {
        const decoded = decode(value).trim();
        if (!decoded) return null;
        try { return new URL(decoded, baseURL || document.baseURI || location.href).href; }
        catch (_) { return null; }
      };
      const pagePoster = () => {
        try {
          const element = document.querySelector(
            'meta[property="og:image"],meta[property="og:image:url"],meta[name="twitter:image"],meta[name="twitter:image:src"]'
          );
          return element && element.getAttribute('content') || '';
        } catch (_) { return ''; }
      };
      const post = (value, kind, poster, title, forcedManifestKind, baseURL) => {
        const url = absolute(value, baseURL);
        if (!url || !/^https?:/i.test(url)) return;
        const inferredManifestKind = /\.mpd(?:$|[?#])/i.test(url)
          ? 'widevineDASH'
          : (/\.m3u8(?:$|[?#])/i.test(url) ? 'hls' : '');
        const hintedManifestKind = forcedManifestKind === 'widevineDASH' || forcedManifestKind === 'hls'
          ? forcedManifestKind
          : '';
        const fallbackManifestKind = forcedManifestKind === 'hlsFallback' ? 'hls' : '';
        const manifestKind = hintedManifestKind || inferredManifestKind || fallbackManifestKind;
        if (!manifestKind) return;
        if (manifestKind === 'widevineDASH') widevineManifestObserved = true;
        const normalizedKind = kind || 'runtime';
        const normalizedPoster = absolute(poster || pagePoster() || '') || '';
        const normalizedTitle = String(title || document.title || '').slice(0, 256);
        const key = `${normalizedKind}\n${manifestKind}\n${url}`;
        const signature = `${normalizedPoster}\n${normalizedTitle}`;
        if (posted.get(key) === signature) return;
        if (!posted.has(key) && posted.size >= maximumPostedEntries) {
          const oldest = posted.keys().next();
          if (!oldest.done) posted.delete(oldest.value);
        }
        posted.set(key, signature);
        try {
          handler.postMessage({
            nonce: probeNonce,
            eventKind: 'media',
            url,
            kind: normalizedKind,
            manifestKind,
            poster: normalizedPoster,
            title: normalizedTitle,
            frameToken,
            sequence: nextSequence()
          });
        } catch (_) {}
      };
      const postWidevineEMESignal = () => {
        widevineKeySystemRequested = true;
        if (widevineEMEPosted) return;
        widevineEMEPosted = true;
        try {
          handler.postMessage({
            nonce: probeNonce,
            eventKind: 'widevineEME',
            frameToken,
            sequence: nextSequence()
          });
        } catch (_) {}
      };
      const headerMetadata = (...headerSets) => {
        const names = new Set();
        let contentType = '';
        headerSets.forEach(headers => {
          if (!headers) return;
          try {
            const normalized = new Headers(headers);
            normalized.forEach((value, name) => {
              const normalizedName = String(name || '').trim().toLowerCase();
              if (!normalizedName || normalizedName.length > 64 || names.size >= 32) return;
              names.add(normalizedName);
              if (normalizedName === 'content-type') contentType = String(value || '').slice(0, 127);
            });
          } catch (_) {}
        });
        return { names: Array.from(names).sort(), contentType };
      };
      const stringByteCount = value => {
        try { return new TextEncoder().encode(String(value || '')).byteLength; }
        catch (_) { return String(value || '').length; }
      };
      const bodyMetadata = (body, contentType) => {
        const normalizedType = String(contentType || '').split(';', 1)[0].trim().toLowerCase();
        if (body == null) return { kind: 'none', byteCount: 0 };
        if (typeof body === 'string') {
          const kind = /json/.test(normalizedType)
            ? 'json'
            : (/application\/x-www-form-urlencoded/.test(normalizedType)
              ? 'formURLEncoded'
              : 'text');
          return { kind, byteCount: stringByteCount(body) };
        }
        try {
          if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) {
            return { kind: 'formURLEncoded', byteCount: stringByteCount(body.toString()) };
          }
          if (typeof ArrayBuffer !== 'undefined' && body instanceof ArrayBuffer) {
            return { kind: 'binary', byteCount: body.byteLength || 0 };
          }
          if (typeof ArrayBuffer !== 'undefined' && ArrayBuffer.isView && ArrayBuffer.isView(body)) {
            return { kind: 'binary', byteCount: body.byteLength || 0 };
          }
          if (typeof Blob !== 'undefined' && body instanceof Blob) {
            return { kind: 'binary', byteCount: body.size || 0 };
          }
          if (typeof FormData !== 'undefined' && body instanceof FormData) {
            return { kind: 'unknown', byteCount: 0 };
          }
        } catch (_) {}
        return { kind: 'unknown', byteCount: 0 };
      };
      const byteView = value => {
        try {
          if (typeof ArrayBuffer !== 'undefined' && value instanceof ArrayBuffer) {
            return new Uint8Array(value);
          }
          if (typeof ArrayBuffer !== 'undefined' && ArrayBuffer.isView && ArrayBuffer.isView(value)) {
            return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
          }
        } catch (_) {}
        return null;
      };
      const base64FromBytes = bytes => {
        try {
          let binary = '';
          for (let offset = 0; offset < bytes.length; offset += 0x4000) {
            binary += String.fromCharCode(...bytes.subarray(offset, Math.min(offset + 0x4000, bytes.length)));
          }
          return btoa(binary);
        } catch (_) { return ''; }
      };
      const rememberEMEMessage = value => {
        const bytes = byteView(value);
        if (!bytes || !bytes.length || bytes.length > maximumInspectableContentLength) {
          emeMessageBytes = null;
          emeMessageBase64 = '';
          return;
        }
        emeMessageBytes = new Uint8Array(bytes);
        emeMessageBase64 = base64FromBytes(emeMessageBytes);
      };
      const bodyMatchesEMEMessage = body => {
        if (!emeMessageBytes || !emeMessageBytes.length) return false;
        const bytes = byteView(body);
        if (bytes) {
          if (bytes.length !== emeMessageBytes.length) return false;
          let difference = 0;
          for (let index = 0; index < bytes.length; index += 1) {
            difference |= bytes[index] ^ emeMessageBytes[index];
          }
          return difference === 0;
        }
        let text = '';
        try {
          if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) {
            text = body.toString();
          } else if (typeof body === 'string') {
            text = body;
          }
        } catch (_) {}
        if (!text || !emeMessageBase64) return false;
        const urlSafeBase64 = emeMessageBase64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
        const candidates = [text];
        try { candidates.push(decodeURIComponent(text)); } catch (_) {}
        return candidates.some(candidate =>
          candidate.includes(emeMessageBase64) || candidate.includes(urlSafeBase64)
        );
      };
      const hasLicenseURLHint = value => {
        try {
          const url = new URL(value, document.baseURI || location.href);
          return /(?:widevine|licen[cs]e|drm|keyserver|key-server|acquire)/i.test(`${url.hostname}${url.pathname}`);
        } catch (_) { return false; }
      };
      const observeLicenseRequest = (value, method, headers, body, baseSource) => {
        const url = absolute(value, document.baseURI || location.href);
        if (!url || !/^https?:/i.test(url)) return;
        const normalizedMethod = String(method || 'GET').trim().toUpperCase().slice(0, 16) || 'GET';
        if (normalizedMethod === 'GET' || normalizedMethod === 'HEAD') return;
        const metadata = headerMetadata(...headers);
        const bodyInfo = bodyMetadata(body, metadata.contentType);
        const emeCorrelated = widevineKeySystemRequested
          && Date.now() <= emeMessageSignalUntil
          && bodyMatchesEMEMessage(body);
        const hinted = widevineManifestObserved && hasLicenseURLHint(url);
        if (!emeCorrelated && !hinted) return;
        const source = emeCorrelated
          ? (baseSource === 'fetch' ? 'emeCorrelatedFetch' : 'emeCorrelatedXMLHttpRequest')
          : baseSource;
        const key = `${source}\n${normalizedMethod}\n${url}\n${metadata.names.join(',')}\n${bodyInfo.kind}`;
        if (postedLicenseRequests.has(key)) return;
        if (postedLicenseRequests.size >= maximumPostedLicenseRequests) return;
        postedLicenseRequests.add(key);
        try {
          handler.postMessage({
            nonce: probeNonce,
            eventKind: 'licenseRequest',
            url,
            method: normalizedMethod,
            contentType: metadata.contentType,
            headerNames: metadata.names,
            bodyKind: bodyInfo.kind,
            bodyByteCount: Math.max(0, Math.min(Number(bodyInfo.byteCount) || 0, 16 * 1024 * 1024)),
            source,
            frameToken,
            sequence: nextSequence()
          });
        } catch (_) {}
      };

      try {
        const originalRequestMediaKeySystemAccess = navigator.requestMediaKeySystemAccess;
        if (typeof originalRequestMediaKeySystemAccess === 'function') {
          const wrappedRequestMediaKeySystemAccess = function(keySystem, ...configurations) {
            if (String(keySystem || '').toLowerCase() === 'com.widevine.alpha') {
              postWidevineEMESignal();
            }
            return Reflect.apply(originalRequestMediaKeySystemAccess, this, [keySystem, ...configurations]);
          };
          try {
            Object.defineProperty(navigator, 'requestMediaKeySystemAccess', {
              configurable: true,
              writable: true,
              value: wrappedRequestMediaKeySystemAccess
            });
          } catch (_) {
            navigator.requestMediaKeySystemAccess = wrappedRequestMediaKeySystemAccess;
          }
        }
      } catch (_) {}

      try {
        const mediaKeySessionPrototype = self.MediaKeySession && self.MediaKeySession.prototype;
        const originalGenerateRequest = mediaKeySessionPrototype && mediaKeySessionPrototype.generateRequest;
        if (typeof originalGenerateRequest === 'function') {
          const listenerInstalled = Symbol('hlsDownloaderWidevineMessageListener');
          mediaKeySessionPrototype.generateRequest = function(...args) {
            try {
              if (widevineKeySystemRequested && !this[listenerInstalled]) {
                this[listenerInstalled] = true;
                this.addEventListener('message', event => {
                  rememberEMEMessage(event && event.message);
                  emeMessageSignalUntil = Date.now() + 15_000;
                  postWidevineEMESignal();
                }, { capture: true });
              }
            } catch (_) {}
            return Reflect.apply(originalGenerateRequest, this, args);
          };
        }
      } catch (_) {}
      const inspectText = (text, responseURL, kind) => {
        const sample = String(text || '').slice(0, maximumBodyBytes);
        if (!sample) return;
        const normalizedSample = decode(sample);
        if (/^\s*#EXTM3U/i.test(normalizedSample)) {
          post(responseURL, kind || 'network', '', document.title, 'hls');
        } else if (/<MPD(?:\s|>)/i.test(normalizedSample)) {
          post(responseURL, kind || 'network', '', document.title, 'widevineDASH');
        }
        const matches = normalizedSample.match(/(?:https?:)?(?:\\?\/\\?\/|\.{0,2}\/)?[^\s\"'<>`]+?\.(?:m3u8|mpd)(?:\?[^\s\"'<>`]*)?/gi) || [];
        matches.slice(0, 64).forEach(value => {
          post(value, kind || 'network', '', document.title, false, responseURL);
        });
      };
      const shouldInspectResponseBody = (type, contentLength) => {
        const normalizedType = String(type || '').split(';', 1)[0].trim().toLowerCase();
        if (!normalizedType || /^(?:video|audio)\//.test(normalizedType) || typeKind(normalizedType)) return false;
        const parsedLength = /^\d+$/.test(String(contentLength || '').trim())
          ? Number(contentLength)
          : null;
        if (parsedLength !== null && (!Number.isFinite(parsedLength) || parsedLength > maximumInspectableContentLength)) {
          return false;
        }
        const isTextual = normalizedType.startsWith('text/')
          || /(?:^|[+/])(?:json|xml)$/.test(normalizedType)
          || /javascript/.test(normalizedType);
        const isOctetStream = normalizedType === 'application/octet-stream';
        return isTextual || (isOctetStream && parsedLength !== null);
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
            const chunk = result.value.byteLength > remaining
              ? result.value.subarray(0, remaining)
              : result.value;
            chunks.push(chunk);
            total += chunk.byteLength;
          }
          if (!total) return;
          const bytes = new Uint8Array(total);
          let offset = 0;
          chunks.forEach(chunk => {
            bytes.set(chunk, offset);
            offset += chunk.byteLength;
          });
          inspectText(new TextDecoder('utf-8').decode(bytes), responseURL, 'network');
        } catch (_) {
        } finally {
          if (reader) {
            try { await reader.cancel(); } catch (_) {}
          }
        }
      };
      const scan = () => {
        try {
          document.querySelectorAll('video').forEach(video => {
            if (!interactive) {
              try { video.muted = true; video.playsInline = true; } catch (_) {}
            }
            const poster = video.poster || video.getAttribute('poster') || video.getAttribute('data-poster') || '';
            const title = video.getAttribute('title') || video.getAttribute('aria-label') || document.title || '';
            const type = video.getAttribute('type') || '';
            ['currentSrc', 'src'].forEach(name => post(video[name], 'video', poster, title, typeKind(type) || 'hlsFallback'));
            ['data-src', 'data-hls-src', 'data-dash-src', 'data-mpd', 'data-video-src', 'data-playlist', 'data-file', 'data-url']
              .forEach(name => post(video.getAttribute(name), 'video', poster, title, false));
            video.querySelectorAll('source').forEach(source => {
              const type = source.type || source.getAttribute('type') || '';
              ['src', 'data-src', 'data-hls-src', 'data-dash-src', 'data-mpd', 'data-file', 'data-url']
                .forEach(name => post(source.getAttribute(name), 'source', poster, title, typeKind(type)));
            });
          });
          document.querySelectorAll('source').forEach(source => {
            const type = source.type || source.getAttribute('type') || '';
            ['src', 'data-src', 'data-hls-src', 'data-dash-src', 'data-mpd', 'data-file', 'data-url']
              .forEach(name => post(source.getAttribute(name), 'source', '', document.title, typeKind(type)));
          });
          document.querySelectorAll('[src],[href],[data-src],[data-hls-src],[data-dash-src],[data-mpd],[data-playlist],[data-file],[data-url]')
            .forEach(element => {
              const type = element.getAttribute('type') || '';
              ['src', 'href', 'data-src', 'data-hls-src', 'data-dash-src', 'data-mpd', 'data-playlist', 'data-file', 'data-url']
                .forEach(name => post(element.getAttribute(name), 'runtime', '', document.title, typeKind(type)));
            });
          document.querySelectorAll('script:not([src])').forEach(script => {
            const text = script.textContent || '';
            const matches = text.match(/(?:https?:)?(?:\\?\/\\?\/|\.{0,2}\/)?[^\s\"'<>`]+?\.(?:m3u8|mpd)(?:\?[^\s\"'<>`]*)?/gi) || [];
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
          window.fetch = function(...args) {
            const input = args[0];
            const init = args[1] || {};
            const isRequest = typeof Request !== 'undefined' && input instanceof Request;
            const requestURL = isRequest ? input.url : input;
            const requestMethod = init.method || (isRequest && input.method) || 'GET';
            const hasExplicitBody = Object.prototype.hasOwnProperty.call(init, 'body');
            const requestBody = hasExplicitBody ? init.body : (isRequest ? input.body : null);
            observeLicenseRequest(
              requestURL,
              requestMethod,
              [isRequest ? input.headers : null, init.headers],
              requestBody,
              'fetch'
            );
            post(input && input.url ? input.url : input, 'network', '', document.title, false);
            return Reflect.apply(originalFetch, this, args).then(response => {
              try {
                const type = response.headers && response.headers.get('content-type');
                const responseURL = response.url || (input && input.url ? input.url : input);
                post(responseURL, 'network', '', document.title, typeKind(type));
                void inspectResponseBody(response, responseURL);
              } catch (_) {}
              return response;
            });
          };
        }
      } catch (_) {}

      try {
        const originalOpen = XMLHttpRequest.prototype.open;
        const originalSend = XMLHttpRequest.prototype.send;
        const originalSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
        const requestURL = Symbol('hlsDownloaderRequestURL');
        const requestMethod = Symbol('hlsDownloaderRequestMethod');
        const requestHeaders = Symbol('hlsDownloaderRequestHeaders');
        XMLHttpRequest.prototype.open = function(method, url, ...rest) {
          this[requestURL] = url;
          this[requestMethod] = method;
          this[requestHeaders] = [];
          post(url, 'network', '', document.title, false);
          this.addEventListener('load', () => {
            try {
              const type = this.getResponseHeader('content-type') || '';
              let manifestKind = '';
              if ((this.responseType === '' || this.responseType === 'text') && typeof this.responseText === 'string') {
                const responseURL = this.responseURL || this[requestURL];
                const sample = this.responseText.slice(0, maximumBodyBytes);
                manifestKind = /^\s*#EXTM3U/i.test(sample)
                  ? 'hls'
                  : (/<MPD(?:\s|>)/i.test(sample) ? 'widevineDASH' : '');
                inspectText(sample, responseURL, 'network');
              }
              post(this.responseURL || this[requestURL], 'network', '', document.title, manifestKind || typeKind(type));
            } catch (_) {}
          }, { once: true });
          return Reflect.apply(originalOpen, this, [method, url, ...rest]);
        };
        XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
          try {
            if (!this[requestHeaders]) this[requestHeaders] = [];
            this[requestHeaders].push([String(name || ''), String(value || '')]);
          } catch (_) {}
          return Reflect.apply(originalSetRequestHeader, this, [name, value]);
        };
        XMLHttpRequest.prototype.send = function(body) {
          observeLicenseRequest(
            this[requestURL],
            this[requestMethod],
            [this[requestHeaders]],
            body,
            'xmlHttpRequest'
          );
          return Reflect.apply(originalSend, this, [body]);
        };
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
          new PerformanceObserver(list => {
            list.getEntries().forEach(entry => post(entry.name, 'network', '', document.title, false));
          }).observe({ type: 'resource', buffered: true });
        } catch (_) {}
        document.addEventListener('loadstart', scan, true);
        document.addEventListener('loadedmetadata', scan, true);
        setInterval(scan, interactive ? 2000 : 750);
      };
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', installObservers, { once: true });
      } else {
        installObservers();
      }
    })();
    """#
}

@MainActor
private final class PlaybackCaptureScriptBridge: NSObject, WKScriptMessageHandler {
    var handler: ((WKScriptMessage) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        handler?(message)
    }
}

/// A user-driven WebKit session that keeps the discovery probe active while the
/// page is visible. The caller owns presentation and is responsible for ending
/// the session with `snapshotAndStop()` before discarding it.
@MainActor
final class PlaybackCaptureSession: NSObject, ObservableObject, WKNavigationDelegate {
    private static let messageName = "hlsDiscovery"
    private static let maximumReferences = 512
    private static let maximumRawMessages = 4_096
    private static let maximumURLLength = 8_192
    private static let maximumLoggedReferences = 64
    private static let maximumNavigationContexts = 1_024
    private static let maximumLicenseRequests = 128

    @Published private(set) var references: [DynamicMediaReference] = []
    @Published private(set) var licenseRequests: [DynamicLicenseReference] = []
    @Published private(set) var detectedWidevineKeySystem = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var currentURL: URL?

    let webView: WKWebView

    let rootURL: URL
    private let seedCookies: [HTTPCookie]
    private let diagnosticSink: DiagnosticSink?
    private let messageNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let websiteDataStore: WKWebsiteDataStore
    private let contentController: WKUserContentController
    private var scriptBridge: PlaybackCaptureScriptBridge?
    private var startupTask: Task<Void, Never>?
    private var isStopping = false
    private var stoppedSnapshot: DynamicPageInspection?
    private var stopWaiters: [CheckedContinuation<DynamicPageInspection, Never>] = []
    private var rawMessageCount = 0
    private var invalidMessageCount = 0
    private var duplicateReferenceCount = 0
    private var blockedNavigationCount = 0
    private var blockedReferenceCount = 0
    private var rawMessageLimitReported = false
    private var referenceLimitReported = false
    private var loggedReferenceCount = 0
    private var referenceLogLimitReported = false
    private var referenceIndexByKey: [String: Int] = [:]
    private var licenseRequestKeys = Set<String>()
    private var navigationContexts: [String: (pageURL: URL, iframeDepth: Int)] = [:]

    init(
        url: URL,
        seedCookies: [HTTPCookie] = [],
        diagnosticSink: DiagnosticSink? = nil
    ) {
        rootURL = url
        self.seedCookies = seedCookies
        self.diagnosticSink = diagnosticSink

        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        self.websiteDataStore = websiteDataStore
        let contentController = WKUserContentController()
        self.contentController = contentController
        contentController.addUserScript(
            WKUserScript(
                source: WebPageInspectionSession.probeJavaScript(
                    interactive: true,
                    messageNonce: messageNonce
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page
            )
        )

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = websiteDataStore
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.applicationNameForUserAgent = "HLSDownloader/1.0"
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        let scriptBridge = PlaybackCaptureScriptBridge()
        scriptBridge.handler = { [weak self] message in
            self?.receive(message)
        }
        self.scriptBridge = scriptBridge
        contentController.add(
            scriptBridge,
            contentWorld: .page,
            name: Self.messageName
        )
        webView.customUserAgent = HTTPClient.userAgent
        webView.navigationDelegate = self
        currentURL = url
    }

    var detectedCount: Int { references.count }

    func start() async {
        if let startupTask {
            await startupTask.value
            return
        }
        guard stoppedSnapshot == nil, !isStopping else { return }
        log(
            "capture start seedCookies=\(seedCookies.count) \(DiagnosticPrivacy.urlSummary(rootURL))"
        )
        let startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.seedCookieStore()
            guard !Task.isCancelled,
                  !self.isStopping,
                  self.stoppedSnapshot == nil,
                  self.isAllowedNavigationURL(self.rootURL) else {
                return
            }
            self.webView.load(
                URLRequest(
                    url: self.rootURL,
                    cachePolicy: .reloadIgnoringLocalCacheData
                )
            )
        }
        self.startupTask = startupTask
        await startupTask.value
    }

    func goBack() {
        guard !isStopping, stoppedSnapshot == nil, webView.canGoBack else { return }
        webView.goBack()
        updateNavigationState()
    }

    func goForward() {
        guard !isStopping, stoppedSnapshot == nil, webView.canGoForward else { return }
        webView.goForward()
        updateNavigationState()
    }

    func reload() {
        guard !isStopping, stoppedSnapshot == nil else { return }
        webView.reload()
    }

    func snapshotAndStop() async -> DynamicPageInspection {
        if let stoppedSnapshot { return stoppedSnapshot }
        if isStopping {
            return await withCheckedContinuation { continuation in
                stopWaiters.append(continuation)
            }
        }

        isStopping = true
        startupTask?.cancel()
        startupTask = nil
        webView.stopLoading()
        let cookies = await allCookies()
        let snapshot = DynamicPageInspection(
            media: references,
            cookies: cookies,
            licenseRequests: licenseRequests,
            detectedWidevineKeySystem: detectedWidevineKeySystem
        )
        stoppedSnapshot = snapshot
        cleanup()
        log(
            "capture finish rawMessages=\(rawMessageCount) invalid=\(invalidMessageCount) duplicates=\(duplicateReferenceCount) accepted=\(references.count) licenseMetadata=\(licenseRequests.count) widevineEME=\(detectedWidevineKeySystem) blockedNavigations=\(blockedNavigationCount) blockedReferences=\(blockedReferenceCount) cookies=\(cookies.count)"
        )

        let waiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: snapshot)
        }
        return snapshot
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        currentURL = webView.url ?? currentURL
        updateNavigationState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        currentURL = webView.url ?? currentURL
        updateNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        currentURL = webView.url ?? currentURL
        updateNavigationState()
        log("capture navigation finished")
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        updateNavigationState()
        log("capture navigation failed error=\(DiagnosticPrivacy.errorCode(error))")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        updateNavigationState()
        log("capture provisional navigation failed error=\(DiagnosticPrivacy.errorCode(error))")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        updateNavigationState()
        log("capture web content process terminated")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard !isStopping, stoppedSnapshot == nil else {
            blockedNavigationCount += 1
            decisionHandler(.cancel)
            return
        }

        guard navigationAction.targetFrame != nil else {
            guard navigationAction.navigationType == .linkActivated,
                  let targetURL = navigationAction.request.url,
                  isAllowedNavigationURL(targetURL) else {
                blockedNavigationCount += 1
                decisionHandler(.cancel)
                return
            }
            log("capture user link opened in current view \(DiagnosticPrivacy.urlSummary(targetURL))")
            decisionHandler(.cancel)
            webView.load(navigationAction.request)
            return
        }

        guard let targetURL = navigationAction.request.url else {
            blockedNavigationCount += 1
            decisionHandler(.cancel)
            return
        }
        if targetURL.scheme?.lowercased() == "about" {
            decisionHandler(.allow)
            return
        }
        guard isAllowedNavigationURL(targetURL) else {
            blockedNavigationCount += 1
            log("capture navigation blocked by URL/private-network policy")
            decisionHandler(.cancel)
            return
        }

        let context = (
            pageURL: trustedFrameURL(from: navigationAction.sourceFrame)
                ?? currentURL
                ?? rootURL,
            iframeDepth: navigationAction.targetFrame?.isMainFrame == true ? 0 : 1
        )
        rememberNavigationContext(context, for: targetURL)
        if let kind = manifestKind(for: targetURL) {
            recordReference(
                url: targetURL,
                kind: kind,
                pageURL: context.pageURL,
                title: nil,
                thumbnailURL: nil,
                iframeDepth: context.iframeDepth,
                origin: context.iframeDepth == 0 ? .runtime : .iframe
            )
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard !isStopping, stoppedSnapshot == nil,
              let targetURL = navigationResponse.response.url else {
            blockedNavigationCount += 1
            decisionHandler(.cancel)
            return
        }
        if targetURL.scheme?.lowercased() == "about" {
            decisionHandler(.allow)
            return
        }
        guard isAllowedNavigationURL(targetURL) else {
            blockedNavigationCount += 1
            decisionHandler(.cancel)
            return
        }
        if let kind = manifestKind(forMIMEType: navigationResponse.response.mimeType) {
            let context = navigationContexts[canonicalKey(targetURL)]
            let depth = context?.iframeDepth ?? (navigationResponse.isForMainFrame ? 0 : 1)
            recordReference(
                url: targetURL,
                kind: kind,
                pageURL: context?.pageURL ?? currentURL ?? rootURL,
                title: nil,
                thumbnailURL: nil,
                iframeDepth: depth,
                origin: depth == 0 ? .runtime : .iframe
            )
        }
        decisionHandler(.allow)
    }

    private func receive(_ message: WKScriptMessage) {
        guard !isStopping,
              stoppedSnapshot == nil,
              message.name == Self.messageName else { return }
        guard rawMessageCount < Self.maximumRawMessages else {
            if !rawMessageLimitReported {
                rawMessageLimitReported = true
                log("capture raw message limit reached limit=\(Self.maximumRawMessages)")
            }
            return
        }
        rawMessageCount += 1
        guard let body = message.body as? [String: Any],
              PlaybackProbePayloadParser.hasValidNonce(body, expected: messageNonce) else {
            invalidMessageCount += 1
            return
        }
        if receiveWidevineProbeEvent(body, message: message) {
            return
        }
        guard
              let rawURL = body["url"] as? String,
              let rawManifestKind = body["manifestKind"] as? String,
              let kind = MediaCandidateKind(rawValue: rawManifestKind),
              rawURL.utf8.count <= Self.maximumURLLength else {
            invalidMessageCount += 1
            return
        }

        let frameURL = trustedFrameURL(from: message.frameInfo) ?? currentURL ?? rootURL
        guard let url = resolvedWebURL(rawURL, relativeTo: frameURL) else {
            invalidMessageCount += 1
            return
        }
        guard AutomaticNavigationPolicy.isAllowedFrameNavigation(
            from: rootURL,
            to: url
        ) else {
            blockedReferenceCount += 1
            log("capture reference blocked by private-network policy")
            return
        }

        let thumbnailURL: URL?
        if let rawPoster = body["poster"] as? String,
           rawPoster.utf8.count <= Self.maximumURLLength,
           let resolvedPoster = resolvedWebURL(rawPoster, relativeTo: frameURL),
           AutomaticNavigationPolicy.isAllowedFrameNavigation(
            from: rootURL,
            to: resolvedPoster
           ) {
            thumbnailURL = resolvedPoster
        } else {
            thumbnailURL = nil
        }
        let title = limitedText(body["title"] as? String, maximumLength: 256)
        let origin: HLSCandidateOrigin
        switch (body["kind"] as? String)?.lowercased() {
        case "video": origin = .video
        case "source": origin = .source
        case "script": origin = .inlineScript
        default: origin = .runtime
        }

        recordReference(
            url: url,
            kind: kind,
            pageURL: frameURL,
            title: title,
            thumbnailURL: thumbnailURL,
            iframeDepth: message.frameInfo.isMainFrame ? 0 : 1,
            origin: origin,
            frameToken: PlaybackProbePayloadParser.normalizedFrameToken(body["frameToken"] as? String),
            sequence: (body["sequence"] as? NSNumber)?.intValue ?? 0
        )
    }

    private func receiveWidevineProbeEvent(
        _ body: [String: Any],
        message: WKScriptMessage
    ) -> Bool {
        switch body["eventKind"] as? String {
        case "widevineEME":
            if !detectedWidevineKeySystem {
                detectedWidevineKeySystem = true
                log("Widevine EME key-system request observed")
            }
            return true
        case "licenseRequest":
            guard let payload = PlaybackProbePayloadParser.licensePayload(from: body) else {
                invalidMessageCount += 1
                return true
            }
            guard let frameURL = trustedFrameURL(from: message.frameInfo),
                  let url = resolvedWebURL(payload.rawURL, relativeTo: frameURL),
                  AutomaticNavigationPolicy.isAllowedFrameNavigation(from: rootURL, to: url) else {
                blockedReferenceCount += 1
                log("capture license metadata blocked by private-network policy")
                return true
            }
            let depth = message.frameInfo.isMainFrame ? 0 : 1
            let key = canonicalKey(url)
                + "\n" + canonicalKey(frameURL)
                + "\n" + (payload.frameToken ?? "")
                + "\n" + payload.metadata.method
                + "\n" + payload.metadata.source.rawValue
            guard licenseRequestKeys.insert(key).inserted else { return true }
            guard licenseRequests.count < Self.maximumLicenseRequests else {
                if !referenceLimitReported {
                    referenceLimitReported = true
                    log("capture license metadata limit reached limit=\(Self.maximumLicenseRequests)")
                }
                return true
            }
            licenseRequests.append(
                DynamicLicenseReference(
                    url: url,
                    pageURL: frameURL,
                    iframeDepth: depth,
                    frameToken: payload.frameToken,
                    metadata: payload.metadata,
                    sequence: payload.sequence
                )
            )
            log(
                "capture license request metadata observed source=\(payload.metadata.source.rawValue) method=\(payload.metadata.method) headers=\(payload.metadata.headerNames.count) body=\(payload.metadata.bodyKind.rawValue)"
            )
            return true
        default:
            return false
        }
    }

    private func recordReference(
        url: URL,
        kind: MediaCandidateKind,
        pageURL: URL,
        title: String?,
        thumbnailURL: URL?,
        iframeDepth: Int,
        origin: HLSCandidateOrigin,
        frameToken: String? = nil,
        sequence: Int = 0
    ) {
        guard !isStopping, stoppedSnapshot == nil else { return }
        guard AutomaticNavigationPolicy.isAllowedFrameNavigation(from: rootURL, to: url) else {
            blockedReferenceCount += 1
            return
        }

        let key = kind.rawValue
            + "\n" + canonicalKey(url)
            + "\n" + canonicalKey(pageURL)
            + "\n" + (frameToken ?? "")
        if let index = referenceIndexByKey[key] {
            duplicateReferenceCount += 1
            let existing = references[index]
            if existing.title == nil && title != nil
                || existing.thumbnailURL == nil && thumbnailURL != nil
                || existing.frameToken == nil && frameToken != nil
                || existing.sequence == 0 && sequence > 0 {
                references[index] = DynamicMediaReference(
                    url: existing.url,
                    kind: existing.kind,
                    pageURL: existing.pageURL,
                    title: existing.title ?? title,
                    thumbnailURL: existing.thumbnailURL ?? thumbnailURL,
                    iframeDepth: existing.iframeDepth,
                    origin: existing.origin,
                    frameToken: existing.frameToken ?? frameToken,
                    sequence: existing.sequence > 0 ? existing.sequence : sequence
                )
            }
            return
        }

        guard references.count < Self.maximumReferences else {
            if !referenceLimitReported {
                referenceLimitReported = true
                log("capture reference limit reached limit=\(Self.maximumReferences)")
            }
            return
        }

        let reference = DynamicMediaReference(
            url: url,
            kind: kind,
            pageURL: pageURL,
            title: title,
            thumbnailURL: thumbnailURL,
            iframeDepth: iframeDepth,
            origin: origin,
            frameToken: frameToken,
            sequence: sequence
        )
        referenceIndexByKey[key] = references.count
        references.append(reference)
        if loggedReferenceCount < Self.maximumLoggedReferences {
            loggedReferenceCount += 1
            log(
                "capture reference added kind=\(kind.rawValue) origin=\(origin.rawValue) depth=\(iframeDepth) thumbnail=\(thumbnailURL != nil) \(DiagnosticPrivacy.urlSummary(url))"
            )
        } else if !referenceLogLimitReported {
            referenceLogLimitReported = true
            log("capture reference detail log limit reached limit=\(Self.maximumLoggedReferences)")
        }
    }

    private func seedCookieStore() async {
        for cookie in seedCookies {
            guard !Task.isCancelled, !isStopping else { return }
            await withCheckedContinuation { continuation in
                websiteDataStore.httpCookieStore.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            websiteDataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
    }

    private func cleanup() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        contentController.removeScriptMessageHandler(
            forName: Self.messageName,
            contentWorld: .page
        )
        contentController.removeAllUserScripts()
        scriptBridge?.handler = nil
        scriptBridge = nil
        updateNavigationState()
    }

    private func updateNavigationState() {
        canGoBack = !isStopping && stoppedSnapshot == nil && webView.canGoBack
        canGoForward = !isStopping && stoppedSnapshot == nil && webView.canGoForward
        currentURL = webView.url ?? currentURL
    }

    private func rememberNavigationContext(
        _ context: (pageURL: URL, iframeDepth: Int),
        for url: URL
    ) {
        let key = canonicalKey(url)
        if navigationContexts[key] == nil,
           navigationContexts.count >= Self.maximumNavigationContexts,
           let evictedKey = navigationContexts.keys.first {
            navigationContexts.removeValue(forKey: evictedKey)
        }
        navigationContexts[key] = context
    }

    private func isAllowedNavigationURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.absoluteString.utf8.count <= Self.maximumURLLength else {
            return false
        }
        return AutomaticNavigationPolicy.isAllowedFrameNavigation(from: rootURL, to: url)
    }

    private func manifestKind(forMIMEType mimeType: String?) -> MediaCandidateKind? {
        guard let mimeType = mimeType?.lowercased() else { return nil }
        if mimeType.contains("application/dash+xml") { return .widevineDASH }
        if mimeType.contains("application/vnd.apple.mpegurl")
            || mimeType.contains("application/x-mpegurl")
            || mimeType.contains("application/mpegurl")
            || mimeType.contains("audio/mpegurl")
            || mimeType.contains("audio/x-mpegurl") {
            return .hls
        }
        return nil
    }

    private func manifestKind(for url: URL) -> MediaCandidateKind? {
        switch url.pathExtension.lowercased() {
        case "m3u8": return .hls
        case "mpd": return .widevineDASH
        default: return nil
        }
    }

    private func trustedFrameURL(from frameInfo: WKFrameInfo) -> URL? {
        guard let url = frameInfo.request.url,
              let resolved = resolvedWebURL(url.absoluteString, relativeTo: rootURL),
              AutomaticNavigationPolicy.isAllowedFrameNavigation(
                from: rootURL,
                to: resolved
              ) else {
            return nil
        }
        return resolved
    }

    private func resolvedWebURL(_ rawValue: String, relativeTo baseURL: URL) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= Self.maximumURLLength,
              let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil,
              url.user == nil,
              url.password == nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.fragment = nil
        guard let resolved = components.url,
              resolved.absoluteString.utf8.count <= Self.maximumURLLength else {
            return nil
        }
        return resolved
    }

    private func canonicalKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    private func limitedText(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumLength))
    }

    private func log(_ message: String) {
        diagnosticSink?(DiagnosticEvent(category: "playback-capture", message: message))
    }
}
