import Foundation

struct HTTPPayload: Sendable {
    let data: Data
    let effectiveURL: URL
    let statusCode: Int
}

final class HTTPClient: @unchecked Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 HLSDownloader/1.0",
            "Accept-Language": "ja,en-US;q=0.8,en;q=0.6"
        ]
        session = URLSession(configuration: configuration)
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
                if let byteRange {
                    request.setValue("bytes=\(byteRange.offset)-\(byteRange.upperBound)", forHTTPHeaderField: "Range")
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
                if let byteRange, http.statusCode == 200 {
                    guard byteRange.offset <= Int64(Int.max),
                          byteRange.length <= Int64(Int.max),
                          byteRange.offset + byteRange.length <= Int64(rawData.count) else {
                        throw HLSError.byteRangeInvalid
                    }
                    let start = Int(byteRange.offset)
                    let end = start + Int(byteRange.length)
                    data = rawData.subdata(in: start..<end)
                } else {
                    data = rawData
                }

                return HTTPPayload(data: data, effectiveURL: effectiveURL, statusCode: http.statusCode)
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

    private func safeReferer(_ referer: URL?, target: URL) -> String? {
        guard let referer,
              let refererScheme = referer.scheme?.lowercased(),
              target.scheme?.lowercased() != nil,
              !(refererScheme == "https" && target.scheme?.lowercased() == "http"),
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
}
