import Foundation

final class HTTPRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var cookieHeaderProvider: ((URL, URL?) -> String?)?
    var responseCookieObserver: ((HTTPURLResponse) -> Void)?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        responseCookieObserver?(response)
        guard let sourceURL = response.url,
              let targetURL = request.url,
              !(sourceURL.scheme?.lowercased() == "https"
                && targetURL.scheme?.lowercased() != "https"),
              AutomaticNavigationPolicy.isAllowedFrameNavigation(
                from: sourceURL,
                to: targetURL
              ) else {
            completionHandler(nil)
            return
        }

        var sanitizedRequest = request
        // A proposed redirect request can retain a manually supplied Cookie
        // header. Always discard it and rebuild against the redirect target so
        // Domain/Path/Secure/expiry and site-context checks cannot be bypassed.
        sanitizedRequest.setValue(nil, forHTTPHeaderField: "Cookie")
        if !Self.isSameOrigin(sourceURL, targetURL) {
            sanitizedRequest.setValue(nil, forHTTPHeaderField: "Authorization")
            sanitizedRequest.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
            sanitizedRequest.setValue(nil, forHTTPHeaderField: "Cookie")
            sanitizedRequest.setValue(
                Self.originString(sourceURL),
                forHTTPHeaderField: "Referer"
            )
        }
        // Keep the top-level site context stable for the entire redirect
        // chain. A redirecting CDN must not become a new first-party context.
        let originalSiteContext = task.originalRequest?
            .value(forHTTPHeaderField: "Referer")
            .flatMap { URL(string: $0) }
        if let originalSiteContext,
           let cookieHeader = cookieHeaderProvider?(targetURL, originalSiteContext) {
            sanitizedRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        completionHandler(sanitizedRequest)
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

    private static func originString(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.path = "/"
        return components.url?.absoluteString
    }
}

private final class HTTPRejectRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct HTTPPayload: Sendable {
    let data: Data
    let effectiveURL: URL
    let statusCode: Int
    let mimeType: String?
}

final class HTTPClient: @unchecked Sendable {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 HLSDownloader/1.0"
    private static let maximumTransientResponseCookies = 512

    private let session: URLSession
    private let redirectDelegate: HTTPRedirectDelegate
    private let transportProtocolClasses: [AnyClass]?
    private let transportConnectionProxyDictionary: [AnyHashable: Any]?
    private let importedCookieLock = NSLock()
    private var importedCookies: [HTTPCookie] = []
    private var transientResponseCookies: [HTTPCookie] = []

    init(configuration: URLSessionConfiguration = .default) {
        transportProtocolClasses = configuration.protocolClasses
        transportConnectionProxyDictionary = configuration.connectionProxyDictionary
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .always
        // Response cookies are ingested explicitly and request cookies are
        // rebuilt through the same Domain/Path/Secure/site-context gate. This
        // prevents URLSession's automatic jar from bypassing that gate.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpMaximumConnectionsPerHost = max(
            configuration.httpMaximumConnectionsPerHost,
            6
        )
        configuration.httpShouldUsePipelining = true
        configuration.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent,
            "Accept-Language": "ja,en-US;q=0.8,en;q=0.6"
        ]
        let redirectDelegate = HTTPRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        redirectDelegate.cookieHeaderProvider = { [weak self] targetURL, referer in
            self?.redirectCookieHeader(for: targetURL, referer: referer)
        }
        redirectDelegate.responseCookieObserver = { [weak self] response in
            self?.storeResponseCookies(from: response)
        }
    }

    deinit {
        session.invalidateAndCancel()
    }

    func cookies(for url: URL) -> [HTTPCookie] {
        importedCookieLock.lock()
        let imported = importedCookies.filter { Self.cookie($0, matches: url) }
        let stored = transientResponseCookies.filter { Self.cookie($0, matches: url) }
        importedCookieLock.unlock()

        var seen = Set<String>()
        return (stored + imported).filter {
            seen.insert("\($0.name)\n\($0.domain)\n\($0.path)").inserted
        }
    }

    func storeCookies(_ cookies: [HTTPCookie]) {
        importedCookieLock.lock()
        importedCookies = cookies.filter { $0.expiresDate.map { $0 > Date() } ?? true }
        importedCookieLock.unlock()
    }

    /// Creates a download-only client with a fresh ephemeral URLSession cookie
    /// jar. Browser cookies and response cookies acquired while resolving the
    /// selected candidate are copied only when their original scope applies to
    /// one of the supplied page/media/license URLs. Set-Cookie responses made
    /// by the returned client remain in that client's private jar and disappear
    /// when the download job releases the client.
    func makeIsolatedDownloadClient(scopedTo observedURLs: [URL]) -> HTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = transportProtocolClasses
        configuration.connectionProxyDictionary = transportConnectionProxyDictionary
        let result = HTTPClient(configuration: configuration)

        importedCookieLock.lock()
        let imported = importedCookies
        let native = transientResponseCookies
        importedCookieLock.unlock()
        var identities = Set<String>()
        let scoped = Self.snapshotCookies(
            native + imported,
            matching: observedURLs
        ).filter { candidate in
            identities.insert(
                "\(candidate.name)\n\(candidate.domain)\n\(candidate.path)"
            ).inserted
        }
        result.storeCookies(scoped)
        return result
    }

    /// The long-lived resolver client must not carry a server response cookie
    /// from one user-initiated discovery into the next discovery. Imported
    /// WebKit cookies are intentionally retained; their persistent source of
    /// truth is WKWebsiteDataStore and `storeCookies` replaces their snapshot.
    func resetTransientResponseCookies() {
        importedCookieLock.lock()
        transientResponseCookies.removeAll(keepingCapacity: false)
        importedCookieLock.unlock()
    }

    /// Filters a persistent browser profile down to cookies that are actually
    /// applicable to an observed page, media, or license URL. The returned
    /// HTTPCookie instances are not reconstructed, so their browser-provided
    /// Domain/Path/Secure/Expires/host-only representation remains intact.
    /// Path is intentionally evaluated only for the eventual request: a page
    /// can observe a manifest under /video while its authenticated segments or
    /// keys use a narrower /segments path on the same cookie host/domain.
    static func snapshotCookies(
        _ cookies: [HTTPCookie],
        matching observedURLs: [URL],
        now: Date = Date()
    ) -> [HTTPCookie] {
        let safeObservedURLs = observedURLs.filter { Self.isSafeHTTPURL($0) }
        guard !safeObservedURLs.isEmpty else { return [] }
        return cookies.filter { candidate in
            safeObservedURLs.contains { observedURL in
                cookieMatchesObservedOrigin(candidate, url: observedURL, now: now)
            }
        }
    }

    func fetch(
        _ candidates: URLCandidates,
        referer: URL? = nil,
        byteRange: ByteRange? = nil
    ) async throws -> HTTPPayload {
        var lastError: Error?

        for candidate in candidates.all {
            do {
                return try await fetch(candidate, referer: referer, byteRange: byteRange)
            } catch let error as HLSError {
                if case .cancelled = error { throw error }
                lastError = error
            } catch {
                if error is CancellationError { throw HLSError.cancelled }
                lastError = error
            }
        }

        if let hlsError = lastError as? HLSError { throw hlsError }
        throw HLSError.network(lastError?.localizedDescription ?? "不明なエラー")
    }

    func fetch(_ url: URL, referer: URL? = nil, byteRange: ByteRange? = nil) async throws -> HTTPPayload {
        var lastError: Error?

        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue("*/*", forHTTPHeaderField: "Accept")
                if let referer = safeReferer(referer, target: url) {
                    request.setValue(referer, forHTTPHeaderField: "Referer")
                }
                if let cookieHeader = requestCookieHeader(for: url, referer: referer) {
                    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                }
                if let byteRange {
                    let upperBound = try checkedUpperBound(byteRange)
                    request.setValue("bytes=\(byteRange.offset)-\(upperBound)", forHTTPHeaderField: "Range")
                }

                let (rawData, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw HLSError.network("HTTPレスポンスを受信できませんでした")
                }
                storeResponseCookies(from: http)
                let effectiveURL = http.url ?? url

                guard (200...299).contains(http.statusCode) else {
                    let error = HLSError.httpStatus(http.statusCode, effectiveURL.host ?? "サーバー")
                    if shouldRetry(status: http.statusCode), attempt < 2 {
                        lastError = error
                        try await backoff(attempt: attempt)
                        continue
                    }
                    throw error
                }

                let data: Data
                if let byteRange {
                    if http.statusCode == 200 {
                        let (endOffset, overflow) = byteRange.offset.addingReportingOverflow(byteRange.length)
                        guard !overflow,
                              byteRange.offset <= Int64(Int.max),
                              byteRange.length <= Int64(Int.max),
                              endOffset <= Int64(rawData.count) else {
                            throw HLSError.byteRangeInvalid
                        }
                        let start = Int(byteRange.offset)
                        let end = start + Int(byteRange.length)
                        data = rawData.subdata(in: start..<end)
                    } else if http.statusCode == 206 {
                        try validatePartialResponse(http, dataCount: rawData.count, expected: byteRange)
                        data = rawData
                    } else {
                        throw HLSError.byteRangeInvalid
                    }
                } else {
                    data = rawData
                }

                return HTTPPayload(
                    data: data,
                    effectiveURL: effectiveURL,
                    statusCode: http.statusCode,
                    mimeType: http.mimeType
                )
            } catch is CancellationError {
                throw HLSError.cancelled
            } catch {
                lastError = error
                if attempt < 2, shouldRetry(error: error) {
                    try await backoff(attempt: attempt)
                    continue
                }
                throw error
            }
        }

        if let hlsError = lastError as? HLSError { throw hlsError }
        throw HLSError.network(lastError?.localizedDescription ?? "不明なエラー")
    }

    func fetchLimited(
        _ url: URL,
        referer: URL? = nil,
        maximumBytes: Int
    ) async throws -> HTTPPayload {
        guard maximumBytes > 0 else { throw HLSError.network("応答サイズの上限が不正です") }
        var lastError: Error?

        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue("image/avif,image/webp,image/*,*/*;q=0.5", forHTTPHeaderField: "Accept")
                if let referer = safeReferer(referer, target: url) {
                    request.setValue(referer, forHTTPHeaderField: "Referer")
                }
                if let cookieHeader = requestCookieHeader(for: url, referer: referer) {
                    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                }

                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw HLSError.network("HTTPレスポンスを受信できませんでした")
                }
                storeResponseCookies(from: http)
                let effectiveURL = http.url ?? url
                guard (200...299).contains(http.statusCode) else {
                    let error = HLSError.httpStatus(http.statusCode, effectiveURL.host ?? "サーバー")
                    if shouldRetry(status: http.statusCode), attempt < 2 {
                        lastError = error
                        try await backoff(attempt: attempt)
                        continue
                    }
                    throw error
                }
                if http.expectedContentLength > Int64(maximumBytes) {
                    throw HLSError.network("画像が大きすぎます")
                }

                var data = Data()
                data.reserveCapacity(min(maximumBytes, max(Int(http.expectedContentLength), 0)))
                for try await byte in bytes {
                    guard data.count < maximumBytes else {
                        throw HLSError.network("画像が大きすぎます")
                    }
                    data.append(byte)
                }
                return HTTPPayload(
                    data: data,
                    effectiveURL: effectiveURL,
                    statusCode: http.statusCode,
                    mimeType: http.mimeType
                )
            } catch is CancellationError {
                throw HLSError.cancelled
            } catch {
                lastError = error
                if attempt < 2, shouldRetry(error: error) {
                    try await backoff(attempt: attempt)
                    continue
                }
                throw error
            }
        }

        if let hlsError = lastError as? HLSError { throw hlsError }
        throw HLSError.network(lastError?.localizedDescription ?? "不明なエラー")
    }

    /// Streams one bounded DASH object directly to a local file. Range
    /// requests must be honored with HTTP 206 so a large shared media object
    /// is never downloaded repeatedly just to extract a small subrange.
    func downloadLimited(
        _ url: URL,
        to destinationURL: URL,
        referer: URL? = nil,
        byteRange: ByteRange? = nil,
        maximumBytes: Int
    ) async throws -> Int64 {
        guard destinationURL.isFileURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              maximumBytes > 0,
              maximumBytes <= 64 * 1_024 * 1_024 else {
            throw HLSError.network("DASH断片の保存条件が不正です")
        }
        if let byteRange {
            guard byteRange.offset >= 0,
                  byteRange.length > 0,
                  byteRange.length <= Int64(maximumBytes) else {
                throw HLSError.byteRangeInvalid
            }
        }

        var lastError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: destinationURL)
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue("video/mp4,audio/mp4,application/octet-stream,*/*;q=0.5", forHTTPHeaderField: "Accept")
                if let referer = safeReferer(referer, target: url) {
                    request.setValue(referer, forHTTPHeaderField: "Referer")
                }
                if let cookieHeader = requestCookieHeader(for: url, referer: referer) {
                    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                }
                if let byteRange {
                    let upperBound = try checkedUpperBound(byteRange)
                    request.setValue("bytes=\(byteRange.offset)-\(upperBound)", forHTTPHeaderField: "Range")
                }

                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw HLSError.network("DASH断片のHTTP応答を受信できませんでした")
                }
                storeResponseCookies(from: http)
                let effectiveURL = http.url ?? url
                guard scheme != "https"
                        || effectiveURL.scheme?.lowercased() == "https" else {
                    throw HLSError.network("DASH断片の安全でないリダイレクトを拒否しました")
                }
                guard (200...299).contains(http.statusCode) else {
                    throw HLSError.httpStatus(
                        http.statusCode,
                        effectiveURL.host ?? "DASH配信サーバー"
                    )
                }
                if byteRange != nil, http.statusCode != 206 {
                    throw HLSError.byteRangeInvalid
                }
                if http.expectedContentLength > Int64(maximumBytes) {
                    throw HLSError.network("DASH断片が大きすぎます")
                }

                guard FileManager.default.createFile(
                    atPath: destinationURL.path,
                    contents: nil
                ) else {
                    throw HLSError.network("DASH断片の一時ファイルを作成できませんでした")
                }
                let output = try FileHandle(forWritingTo: destinationURL)
                var buffer = Data()
                buffer.reserveCapacity(64 * 1_024)
                var written: Int64 = 0
                do {
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard written < Int64(maximumBytes) else {
                            throw HLSError.network("DASH断片が大きすぎます")
                        }
                        buffer.append(byte)
                        written += 1
                        if buffer.count == 64 * 1_024 {
                            try output.write(contentsOf: buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        try output.write(contentsOf: buffer)
                    }
                    try output.close()
                } catch {
                    try? output.close()
                    throw error
                }

                guard written > 0, written <= Int64(maximumBytes) else {
                    throw HLSError.network("DASH断片が空か大きすぎます")
                }
                if let byteRange {
                    guard written <= Int64(Int.max) else {
                        throw HLSError.byteRangeInvalid
                    }
                    try validatePartialResponse(
                        http,
                        dataCount: Int(written),
                        expected: byteRange
                    )
                }
                return written
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: destinationURL)
                throw HLSError.cancelled
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                if let urlError = error as? URLError,
                   urlError.code == .cancelled {
                    throw HLSError.cancelled
                }
                lastError = error
                if attempt < 2, shouldRetry(error: error) {
                    try await backoff(attempt: attempt)
                    continue
                }
                throw error
            }
        }

        try? FileManager.default.removeItem(at: destinationURL)
        if let hlsError = lastError as? HLSError { throw hlsError }
        throw HLSError.network("DASH断片の取得に失敗しました")
    }

    /// Sends a bounded, non-redirecting POST used by the Widevine license
    /// transport. The caller owns the header values; this method never logs
    /// them and refuses request-controlled transport headers.
    func postLimited(
        _ url: URL,
        headers: [String: String],
        body: Data,
        referer: URL?,
        maximumResponseBytes: Int
    ) async throws -> HTTPPayload {
        guard let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              url.host != nil,
              url.user == nil,
              url.password == nil,
              maximumResponseBytes > 0,
              maximumResponseBytes <= 16 * 1_024 * 1_024,
              body.count <= 4 * 1_024 * 1_024 else {
            throw HLSError.network("Widevineライセンス要求が安全な上限を超えています")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/octet-stream,application/json;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        for (name, value) in try validatedRequestHeaders(headers) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let referer = safeReferer(referer, target: url) {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if request.value(forHTTPHeaderField: "Origin") == nil,
           let origin = safeOrigin(referer, target: url) {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        if let cookieHeader = requestCookieHeader(for: url, referer: referer) {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent,
            "Accept-Language": "ja,en-US;q=0.8,en;q=0.6"
        ]
        let delegate = HTTPRejectRedirectDelegate()
        let licenseSession = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { licenseSession.invalidateAndCancel() }

        do {
            let (bytes, response) = try await licenseSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HLSError.network("WidevineライセンスサーバーからHTTP応答を受信できませんでした")
            }
            storeResponseCookies(from: http)
            let effectiveURL = http.url ?? url
            guard (200...299).contains(http.statusCode) else {
                throw HLSError.httpStatus(
                    http.statusCode,
                    effectiveURL.host ?? "ライセンスサーバー"
                )
            }
            if http.expectedContentLength > Int64(maximumResponseBytes) {
                throw HLSError.network("Widevineライセンス応答が大きすぎます")
            }

            var data = Data()
            data.reserveCapacity(
                min(maximumResponseBytes, max(Int(http.expectedContentLength), 0))
            )
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumResponseBytes else {
                    throw HLSError.network("Widevineライセンス応答が大きすぎます")
                }
                data.append(byte)
            }
            guard !data.isEmpty else {
                throw HLSError.network("Widevineライセンス応答が空です")
            }
            return HTTPPayload(
                data: data,
                effectiveURL: effectiveURL,
                statusCode: http.statusCode,
                mimeType: http.mimeType
            )
        } catch is CancellationError {
            throw HLSError.cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw HLSError.cancelled
        } catch let error as HLSError {
            throw error
        } catch {
            throw HLSError.network("Widevineライセンス通信に失敗しました")
        }
    }

    private func shouldRetry(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    private func validatedRequestHeaders(_ headers: [String: String]) throws -> [(String, String)] {
        guard headers.count <= 32 else {
            throw HLSError.network("Widevineライセンス要求ヘッダーが多すぎます")
        }
        let forbidden = Set([
            "connection", "content-length", "cookie", "host", "proxy-authorization",
            "referer", "transfer-encoding", "user-agent"
        ])
        let tokenCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"
        )
        var result: [(String, String)] = []
        result.reserveCapacity(headers.count)
        for (name, value) in headers {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty,
                  trimmedName.utf8.count <= 64,
                  trimmedName.unicodeScalars.allSatisfy({
                      tokenCharacters.contains($0)
                  }),
                  !forbidden.contains(trimmedName.lowercased()),
                  value.utf8.count <= 8_192,
                  !value.contains("\r"),
                  !value.contains("\n"),
                  !value.contains("\0") else {
                throw HLSError.network("Widevineライセンス要求ヘッダーが不正です")
            }
            result.append((trimmedName, value))
        }
        return result
    }

    private func shouldRetry(error: Error) -> Bool {
        if let hls = error as? HLSError {
            if case .httpStatus(let status, _) = hls { return shouldRetry(status: status) }
            return false
        }
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut,
            .cannotConnectToHost,
            .networkConnectionLost,
            .notConnectedToInternet,
            .dnsLookupFailed
        ].contains(urlError.code)
    }

    private func backoff(attempt: Int) async throws {
        let nanoseconds = UInt64(500_000_000 * (attempt + 1))
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch is CancellationError {
            throw HLSError.cancelled
        }
    }

    private func checkedUpperBound(_ range: ByteRange) throws -> Int64 {
        guard range.offset >= 0, range.length > 0 else { throw HLSError.byteRangeInvalid }
        let (endOffset, overflow) = range.offset.addingReportingOverflow(range.length)
        guard !overflow, endOffset > range.offset else { throw HLSError.byteRangeInvalid }
        return endOffset - 1
    }

    private func validatePartialResponse(
        _ response: HTTPURLResponse,
        dataCount: Int,
        expected: ByteRange
    ) throws {
        guard let expectedLength = Int(exactly: expected.length),
              dataCount == expectedLength,
              let contentRange = response.value(forHTTPHeaderField: "Content-Range")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              contentRange.lowercased().hasPrefix("bytes ") else {
            throw HLSError.byteRangeInvalid
        }

        let value = contentRange.dropFirst(6)
        let rangeAndTotal = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard rangeAndTotal.count == 2 else { throw HLSError.byteRangeInvalid }
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let expectedUpperBound = try checkedUpperBound(expected)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start == expected.offset,
              end == expectedUpperBound else {
            throw HLSError.byteRangeInvalid
        }
        if rangeAndTotal[1] != "*" {
            guard let total = Int64(rangeAndTotal[1]), total > end else {
                throw HLSError.byteRangeInvalid
            }
        }
    }

    private func safeReferer(_ referer: URL?, target: URL) -> String? {
        guard let referer,
              let refererScheme = referer.scheme?.lowercased(),
              let targetScheme = target.scheme?.lowercased(),
              !(refererScheme == "https" && targetScheme == "http"),
              var components = URLComponents(url: referer, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.user = nil
        components.password = nil
        components.fragment = nil
        if !isSameOrigin(referer, target) {
            components.path = "/"
            components.percentEncodedQuery = nil
        }
        return components.url?.absoluteString
    }

    private func safeOrigin(_ source: URL?, target: URL) -> String? {
        guard let source,
              let sourceScheme = source.scheme?.lowercased(),
              let targetScheme = target.scheme?.lowercased(),
              sourceScheme == "http" || sourceScheme == "https",
              !(sourceScheme == "https" && targetScheme == "http"),
              let host = source.host?.lowercased(),
              source.user == nil,
              source.password == nil else {
            return nil
        }
        var components = URLComponents()
        components.scheme = sourceScheme
        components.host = host
        components.port = source.port
        return components.string
    }

    private func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private func requestCookieHeader(for url: URL, referer: URL?) -> String? {
        importedCookieLock.lock()
        let imported = importedCookies
        let stored = transientResponseCookies
        importedCookieLock.unlock()

        var identities = Set<String>()
        // A Set-Cookie received later in this job supersedes the seed snapshot
        // for the same name/domain/path identity.
        let matching = (stored + imported).filter { candidate in
            let identity = "\(candidate.name)\n\(candidate.domain)\n\(candidate.path)"
            return identities.insert(identity).inserted
                && Self.cookie(candidate, matches: url)
                && Self.cookieIsAllowedBySiteContext(
                    candidate,
                    target: url,
                    referer: referer
                )
        }
        guard !matching.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
    }

    private func redirectCookieHeader(for url: URL, referer: URL?) -> String? {
        requestCookieHeader(for: url, referer: referer)
    }

    private func storeResponseCookies(from response: HTTPURLResponse) {
        guard let responseURL = response.url else { return }
        var fields: [String: String] = [:]
        for (rawName, rawValue) in response.allHeaderFields {
            guard let name = rawName as? String else { continue }
            fields[name] = String(describing: rawValue)
        }
        let received = HTTPCookie.cookies(
            withResponseHeaderFields: fields,
            for: responseURL
        )
        guard !received.isEmpty else { return }

        let now = Date()
        importedCookieLock.lock()
        transientResponseCookies.removeAll { existing in
            existing.expiresDate.map { $0 <= now } ?? false
        }
        for cookie in received {
            transientResponseCookies.removeAll {
                Self.cookieIdentity($0) == Self.cookieIdentity(cookie)
            }
            if !Self.isDeletionCookie(cookie, now: now) {
                transientResponseCookies.append(cookie)
            }
        }
        if transientResponseCookies.count > Self.maximumTransientResponseCookies {
            transientResponseCookies.removeFirst(
                transientResponseCookies.count - Self.maximumTransientResponseCookies
            )
        }
        importedCookieLock.unlock()
    }

    private static func cookieIdentity(_ cookie: HTTPCookie) -> String {
        "\(cookie.name)\n\(cookie.domain)\n\(cookie.path)"
    }

    private static func isDeletionCookie(_ cookie: HTTPCookie, now: Date) -> Bool {
        if cookie.expiresDate.map({ $0 <= now }) == true { return true }
        guard let rawMaximumAge = cookie.properties?[.maximumAge] else { return false }
        if let value = rawMaximumAge as? NSNumber {
            return cookie.value.isEmpty && value.intValue <= 0
        }
        if let value = rawMaximumAge as? String,
           let seconds = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return cookie.value.isEmpty && seconds <= 0
        }
        return false
    }

    private static func cookie(
        _ cookie: HTTPCookie,
        matches url: URL,
        now: Date = Date()
    ) -> Bool {
        guard cookieMatchesObservedOrigin(cookie, url: url, now: now) else {
            return false
        }

        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if requestPath.count > cookiePath.count,
           !cookiePath.hasSuffix("/"),
           requestPath.dropFirst(cookiePath.count).first != "/" {
            return false
        }
        return true
    }

    private static func cookieMatchesObservedOrigin(
        _ cookie: HTTPCookie,
        url: URL,
        now: Date
    ) -> Bool {
        guard isSafeHTTPURL(url),
              let host = url.host?.lowercased(),
              let domain = normalizedCookieDomain(cookie) else {
            return false
        }
        guard domainMatches(host, domain: domain.value, includeSubdomains: domain.isDomainCookie) else {
            return false
        }
        if cookie.isSecure, url.scheme?.lowercased() != "https" { return false }
        if let expires = cookie.expiresDate, expires <= now { return false }
        return true
    }

    /// URLSession does not enforce browser SameSite semantics for a Cookie
    /// header supplied by the app. Treat a direct URL as its own top-level
    /// context, but otherwise require a schemeful exact-host relationship. A
    /// browser-identified Domain cookie may cross sibling hosts only when both
    /// hosts are inside that cookie's declared domain. Unknown host-only state
    /// is therefore handled as host-only and fails closed across hosts.
    private static func cookieIsAllowedBySiteContext(
        _ cookie: HTTPCookie,
        target: URL,
        referer: URL?
    ) -> Bool {
        let siteContext = referer ?? target
        guard isSafeHTTPURL(target),
              isSafeHTTPURL(siteContext),
              target.scheme?.lowercased() == siteContext.scheme?.lowercased(),
              let targetHost = target.host?.lowercased(),
              let contextHost = siteContext.host?.lowercased(),
              let domain = normalizedCookieDomain(cookie) else {
            return false
        }

        if domain.isDomainCookie {
            return domainMatches(targetHost, domain: domain.value, includeSubdomains: true)
                && domainMatches(contextHost, domain: domain.value, includeSubdomains: true)
        }
        return targetHost == domain.value && contextHost == targetHost
    }

    private static func normalizedCookieDomain(
        _ cookie: HTTPCookie
    ) -> (value: String, isDomainCookie: Bool)? {
        let raw = cookie.domain.lowercased()
        let isDomainCookie = raw.hasPrefix(".")
        let value = isDomainCookie ? String(raw.dropFirst()) : raw
        guard !value.isEmpty,
              !value.hasPrefix("."),
              !value.hasSuffix("."),
              !value.contains(where: { $0.isWhitespace }) else {
            return nil
        }
        return (value, isDomainCookie)
    }

    private static func domainMatches(
        _ host: String,
        domain: String,
        includeSubdomains: Bool
    ) -> Bool {
        host == domain || (includeSubdomains && host.hasSuffix(".\(domain)"))
    }

    private static func isSafeHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            return false
        }
        return true
    }
}
