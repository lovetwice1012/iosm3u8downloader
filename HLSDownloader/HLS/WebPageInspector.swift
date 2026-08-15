import Combine
import Foundation
import WebKit

struct DynamicMediaReference: Sendable {
    let url: URL
    let pageURL: URL
    let title: String?
    let thumbnailURL: URL?
    let iframeDepth: Int
    let origin: HLSCandidateOrigin
}

struct DynamicPageInspection: @unchecked Sendable {
    let media: [DynamicMediaReference]
    let cookies: [HTTPCookie]

    static let empty = DynamicPageInspection(media: [], cookies: [])
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

    private let rootURL: URL
    private let seedCookies: [HTTPCookie]
    private let diagnosticSink: DiagnosticSink?
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
                source: Self.probeJavaScript(interactive: false),
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
            "finish reason=\(reason.rawValue) rawMessages=\(rawMessageCount) invalid=\(invalidMessageCount) duplicates=\(duplicateReferenceCount) accepted=\(media.count) blockedNavigations=\(blockedNavigationCount) rawLimit=\(rawMessageLimitReached) referenceLimit=\(referenceLimitReached) cookies=\(cookies.count)"
        )
        self.continuation = nil
        continuation.resume(returning: DynamicPageInspection(media: media, cookies: cookies))
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
            if targetURL.path.range(
                of: #"\.m3u8$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                recordReference(
                    url: targetURL,
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
        if isHLSMimeType(navigationResponse.response.mimeType) {
            let context = navigationContexts[canonicalKey(targetURL)]
            recordReference(
                url: targetURL,
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
              let rawURL = body["url"] as? String,
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
            pageURL: frameURL,
            title: title,
            thumbnailURL: thumbnailURL,
            iframeDepth: message.frameInfo.isMainFrame ? 0 : 1,
            origin: origin
        )
    }

    private func recordReference(
        url: URL,
        pageURL: URL,
        title: String?,
        thumbnailURL: URL?,
        iframeDepth: Int,
        origin: HLSCandidateOrigin
    ) {
        let key = canonicalKey(url) + "\n" + canonicalKey(pageURL)
        var didChange = false
        if let existing = references[key] {
            duplicateReferenceCount += 1
            if existing.title == nil && title != nil || existing.thumbnailURL == nil && thumbnailURL != nil {
                references[key] = DynamicMediaReference(
                    url: existing.url,
                    pageURL: existing.pageURL,
                    title: existing.title ?? title,
                    thumbnailURL: existing.thumbnailURL ?? thumbnailURL,
                    iframeDepth: existing.iframeDepth,
                    origin: existing.origin
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
                pageURL: pageURL,
                title: title,
                thumbnailURL: thumbnailURL,
                iframeDepth: iframeDepth,
                origin: origin
            )
            referenceOrder.append(key)
            if loggedReferenceCount < Self.maximumLoggedReferences {
                loggedReferenceCount += 1
                log(
                    "reference added origin=\(origin.rawValue) depth=\(iframeDepth) thumbnail=\(thumbnailURL != nil) \(DiagnosticPrivacy.urlSummary(url))"
                )
            } else if !referenceLogLimitReported {
                referenceLogLimitReported = true
                log("reference detail log limit reached limit=\(Self.maximumLoggedReferences)")
            }
            didChange = true
        }
        if didChange { scheduleSettle() }
    }

    private func isHLSMimeType(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased() else { return false }
        return mimeType.contains("application/vnd.apple.mpegurl")
            || mimeType.contains("application/x-mpegurl")
            || mimeType.contains("application/mpegurl")
            || mimeType.contains("audio/mpegurl")
            || mimeType.contains("audio/x-mpegurl")
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

    fileprivate static func probeJavaScript(interactive: Bool) -> String {
        probeJavaScriptTemplate.replacingOccurrences(
            of: "__HLS_DOWNLOADER_INTERACTIVE__",
            with: interactive ? "true" : "false"
        )
    }

    private static let probeJavaScriptTemplate = #"""
    (() => {
      if (window.__hlsDownloaderProbeInstalled) return;
      window.__hlsDownloaderProbeInstalled = true;
      const interactive = __HLS_DOWNLOADER_INTERACTIVE__;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hlsDiscovery;
      if (!handler) return;
      const posted = new Map();
      const maximumPostedEntries = 2048;
      const maximumBodyBytes = 64 * 1024;
      const maximumInspectableContentLength = 1024 * 1024;
      const hlsType = value => /(?:application|audio)\/(?:vnd\.apple\.mpegurl|x-mpegurl|mpegurl)/i.test(value || '');
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
      const post = (value, kind, poster, title, force, baseURL) => {
        const url = absolute(value, baseURL);
        if (!url || !/^https?:/i.test(url)) return;
        if (!force && !/\.m3u8(?:$|[?#])/i.test(url)) return;
        const normalizedKind = kind || 'runtime';
        const normalizedPoster = absolute(poster || pagePoster() || '') || '';
        const normalizedTitle = String(title || document.title || '').slice(0, 256);
        const key = `${normalizedKind}\n${url}`;
        const signature = `${normalizedPoster}\n${normalizedTitle}`;
        if (posted.get(key) === signature) return;
        if (!posted.has(key) && posted.size >= maximumPostedEntries) {
          const oldest = posted.keys().next();
          if (!oldest.done) posted.delete(oldest.value);
        }
        posted.set(key, signature);
        try {
          handler.postMessage({
            url,
            kind: normalizedKind,
            poster: normalizedPoster,
            title: normalizedTitle
          });
        } catch (_) {}
      };
      const inspectText = (text, responseURL, kind) => {
        const sample = String(text || '').slice(0, maximumBodyBytes);
        if (!sample) return;
        const normalizedSample = decode(sample);
        if (/^\s*#EXTM3U/i.test(normalizedSample)) {
          post(responseURL, kind || 'network', '', document.title, true);
        }
        const matches = normalizedSample.match(/(?:https?:)?(?:\\?\/\\?\/|\.{0,2}\/)?[^\s\"'<>`]+?\.m3u8(?:\?[^\s\"'<>`]*)?/gi) || [];
        matches.slice(0, 64).forEach(value => {
          post(value, kind || 'network', '', document.title, false, responseURL);
        });
      };
      const shouldInspectResponseBody = (type, contentLength) => {
        const normalizedType = String(type || '').split(';', 1)[0].trim().toLowerCase();
        if (!normalizedType || /^(?:video|audio)\//.test(normalizedType) || hlsType(normalizedType)) return false;
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
            const text = script.textContent || '';
            const matches = text.match(/(?:https?:)?(?:\\?\/\\?\/|\.{0,2}\/)?[^\s\"'<>`]+?\.m3u8(?:\?[^\s\"'<>`]*)?/gi) || [];
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
        XMLHttpRequest.prototype.open = function(method, url, ...rest) {
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
          return Reflect.apply(originalOpen, this, [method, url, ...rest]);
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

    @Published private(set) var references: [DynamicMediaReference] = []
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var currentURL: URL?

    let webView: WKWebView

    let rootURL: URL
    private let seedCookies: [HTTPCookie]
    private let diagnosticSink: DiagnosticSink?
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
                source: WebPageInspectionSession.probeJavaScript(interactive: true),
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
        let snapshot = DynamicPageInspection(media: references, cookies: cookies)
        stoppedSnapshot = snapshot
        cleanup()
        log(
            "capture finish rawMessages=\(rawMessageCount) invalid=\(invalidMessageCount) duplicates=\(duplicateReferenceCount) accepted=\(references.count) blockedNavigations=\(blockedNavigationCount) blockedReferences=\(blockedReferenceCount) cookies=\(cookies.count)"
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
        if targetURL.path.range(
            of: #"\.m3u8$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            recordReference(
                url: targetURL,
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
        if isHLSMimeType(navigationResponse.response.mimeType) {
            let context = navigationContexts[canonicalKey(targetURL)]
            let depth = context?.iframeDepth ?? (navigationResponse.isForMainFrame ? 0 : 1)
            recordReference(
                url: targetURL,
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
              let rawURL = body["url"] as? String,
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
            pageURL: frameURL,
            title: title,
            thumbnailURL: thumbnailURL,
            iframeDepth: message.frameInfo.isMainFrame ? 0 : 1,
            origin: origin
        )
    }

    private func recordReference(
        url: URL,
        pageURL: URL,
        title: String?,
        thumbnailURL: URL?,
        iframeDepth: Int,
        origin: HLSCandidateOrigin
    ) {
        guard !isStopping, stoppedSnapshot == nil else { return }
        guard AutomaticNavigationPolicy.isAllowedFrameNavigation(from: rootURL, to: url) else {
            blockedReferenceCount += 1
            return
        }

        let key = canonicalKey(url) + "\n" + canonicalKey(pageURL)
        if let index = referenceIndexByKey[key] {
            duplicateReferenceCount += 1
            let existing = references[index]
            if existing.title == nil && title != nil
                || existing.thumbnailURL == nil && thumbnailURL != nil {
                references[index] = DynamicMediaReference(
                    url: existing.url,
                    pageURL: existing.pageURL,
                    title: existing.title ?? title,
                    thumbnailURL: existing.thumbnailURL ?? thumbnailURL,
                    iframeDepth: existing.iframeDepth,
                    origin: existing.origin
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
            pageURL: pageURL,
            title: title,
            thumbnailURL: thumbnailURL,
            iframeDepth: iframeDepth,
            origin: origin
        )
        referenceIndexByKey[key] = references.count
        references.append(reference)
        if loggedReferenceCount < Self.maximumLoggedReferences {
            loggedReferenceCount += 1
            log(
                "capture reference added origin=\(origin.rawValue) depth=\(iframeDepth) thumbnail=\(thumbnailURL != nil) \(DiagnosticPrivacy.urlSummary(url))"
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

    private func isHLSMimeType(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased() else { return false }
        return mimeType.contains("application/vnd.apple.mpegurl")
            || mimeType.contains("application/x-mpegurl")
            || mimeType.contains("application/mpegurl")
            || mimeType.contains("audio/mpegurl")
            || mimeType.contains("audio/x-mpegurl")
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
