import Foundation

final class HTTPRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let sourceURL = response.url,
              let targetURL = request.url,
              AutomaticNavigationPolicy.isAllowedFrameNavigation(
                from: sourceURL,
                to: targetURL
              ) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
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

    private let session: URLSession
    private let redirectDelegate: HTTPRedirectDelegate
    private let cookieStorage: HTTPCookieStorage?
    private let importedCookieLock = NSLock()
    private var importedCookies: [HTTPCookie] = []

    init(configuration: URLSessionConfiguration = .default) {
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.httpMaximumConnectionsPerHost = max(
            configuration.httpMaximumConnectionsPerHost,
            6
        )
        configuration.httpShouldUsePipelining = true
        configuration.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent,
            "Accept-Language": "ja,en-US;q=0.8,en;q=0.6"
        ]
        cookieStorage = configuration.httpCookieStorage
        let redirectDelegate = HTTPRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    func cookies(for url: URL) -> [HTTPCookie] {
        let stored = cookieStorage?.cookies(for: url) ?? []
        importedCookieLock.lock()
        let imported = importedCookies.filter { cookie($0, matches: url) }
        importedCookieLock.unlock()

        var seen = Set<String>()
        return (imported + stored).filter {
            seen.insert("\($0.name)\n\($0.domain)\n\($0.path)").inserted
        }
    }

    func storeCookies(_ cookies: [HTTPCookie]) {
        importedCookieLock.lock()
        importedCookies = cookies.filter { $0.expiresDate.map { $0 > Date() } ?? true }
        importedCookieLock.unlock()
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
                if let cookieHeader = importedCookieHeader(for: url) {
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
                if let cookieHeader = importedCookieHeader(for: url) {
                    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                }

                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw HLSError.network("HTTPレスポンスを受信できませんでした")
                }
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

    private func shouldRetry(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
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
        try await Task.sleep(nanoseconds: nanoseconds)
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

    private func importedCookieHeader(for url: URL) -> String? {
        importedCookieLock.lock()
        let matching = importedCookies.filter { cookie($0, matches: url) }
        importedCookieLock.unlock()
        guard !matching.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
    }

    private func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let rawCookieDomain = cookie.domain.lowercased()
        let isDomainCookie = rawCookieDomain.hasPrefix(".")
        let cookieDomain = rawCookieDomain.trimmingCharacters(
            in: CharacterSet(charactersIn: ".")
        )
        guard !cookieDomain.isEmpty else { return false }
        guard host == cookieDomain || (isDomainCookie && host.hasSuffix(".\(cookieDomain)")) else {
            return false
        }
        if cookie.isSecure, url.scheme?.lowercased() != "https" { return false }
        if let expires = cookie.expiresDate, expires <= Date() { return false }

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
}
