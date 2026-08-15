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
    func inspect(url: URL, seedCookies: [HTTPCookie]) async -> DynamicPageInspection {
        let session = WebPageInspectionSession(url: url, seedCookies: seedCookies)
        return await session.run()
    }
}

@MainActor
private final class WebPageInspectionSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private static let messageName = "hlsDiscovery"
    private static let maximumMessages = 512
    private static let maximumRawMessages = 4_096
    private static let maximumURLLength = 8_192

    private let rootURL: URL
    private let seedCookies: [HTTPCookie]
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
    private var references: [String: DynamicMediaReference] = [:]
    private var referenceOrder: [String] = []
    private var navigationContexts: [String: (pageURL: URL, iframeDepth: Int)] = [:]

    init(url: URL, seedCookies: [HTTPCookie]) {
        rootURL = url
        self.seedCookies = seedCookies
    }

    func run() async -> DynamicPageInspection {
        await seedCookieStore()

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                startWebView()
                if Task.isCancelled || finishRequested {
                    Task { @MainActor [weak self] in
                        await self?.finish()
                    }
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.finishRequested = true
                await self?.finish()
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
                source: Self.probeJavaScript,
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
            await self?.finish()
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

    private func scheduleSettle(after nanoseconds: UInt64 = 6_000_000_000) {
        guard navigationFinished, !isFinishing else { return }
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.finish()
        }
    }

    private func finish() async {
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
        self.continuation = nil
        continuation.resume(returning: DynamicPageInspection(media: media, cookies: cookies))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationFinished = true
        scheduleSettle(after: 6_000_000_000)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationFinished = true
        scheduleSettle(after: 750_000_000)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationFinished = true
        scheduleSettle(after: 750_000_000)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationFinished = true
        scheduleSettle(after: 100_000_000)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame != nil else {
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
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard let targetURL = navigationResponse.response.url else {
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
        guard message.name == Self.messageName,
              rawMessageCount < Self.maximumRawMessages else {
            return
        }
        rawMessageCount += 1
        guard let body = message.body as? [String: Any],
              let rawURL = body["url"] as? String,
              rawURL.utf8.count <= Self.maximumURLLength else {
            return
        }

        let frameURL = trustedFrameURL(from: message.frameInfo) ?? rootURL
        guard let url = resolvedWebURL(rawURL, relativeTo: frameURL) else { return }
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
            guard messageCount < Self.maximumMessages else { return }
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

    private static let probeJavaScript = #"""
    (() => {
      if (window.__hlsDownloaderProbeInstalled) return;
      window.__hlsDownloaderProbeInstalled = true;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hlsDiscovery;
      if (!handler) return;
      const posted = new Map();
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
      const absolute = value => {
        const decoded = decode(value).trim();
        if (!decoded) return null;
        try { return new URL(decoded, document.baseURI || location.href).href; }
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
      const post = (value, kind, poster, title, force) => {
        const url = absolute(value);
        if (!url || !/^https?:/i.test(url)) return;
        if (!force && !/\.m3u8(?:$|[?#])/i.test(url)) return;
        const normalizedKind = kind || 'runtime';
        const normalizedPoster = absolute(poster || pagePoster() || '') || '';
        const normalizedTitle = String(title || document.title || '').slice(0, 256);
        const key = `${normalizedKind}\n${url}`;
        const signature = `${normalizedPoster}\n${normalizedTitle}`;
        if (posted.get(key) === signature) return;
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
      const scan = () => {
        try {
          document.querySelectorAll('video').forEach(video => {
            try { video.muted = true; video.playsInline = true; } catch (_) {}
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
                post(response.url || (input && input.url ? input.url : input), 'network', '', document.title, hlsType(type));
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
                manifest = /^\s*#EXTM3U/i.test(this.responseText.slice(0, 128));
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
        setInterval(scan, 750);
      };
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', installObservers, { once: true });
      } else {
        installObservers();
      }
    })();
    """#
}
