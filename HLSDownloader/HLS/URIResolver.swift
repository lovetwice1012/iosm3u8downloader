import Foundation

enum URIResolver {
    static func normalizeInput(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HLSError.invalidURL }

        let value: String
        if trimmed.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil {
            value = trimmed
        } else {
            value = "https://\(trimmed)"
        }

        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
            throw HLSError.invalidURL
        }
        guard scheme == "https" || scheme == "http" else {
            throw HLSError.unsupportedScheme
        }
        return url
    }

    static func resolve(_ rawValue: String, relativeTo baseURL: URL) throws -> URLCandidates {
        let decoded = decodeEscapes(rawValue)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'"))

        let primary: URL?
        if decoded.hasPrefix("//"), let scheme = baseURL.scheme {
            primary = URL(string: "\(scheme):\(decoded)")
        } else {
            primary = URL(string: decoded, relativeTo: baseURL)?.absoluteURL
        }

        guard let primary,
              let scheme = primary.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw HLSError.invalidURL
        }

        var fallback: URL?
        if primary.query == nil,
           let baseQuery = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
           isSameOrigin(primary, baseURL),
           var components = URLComponents(url: primary, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = baseQuery
            fallback = components.url
        }

        return URLCandidates(primary: primary, sameOriginQueryFallback: fallback)
    }

    static func decodeEscapes(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u002F", with: "/", options: .caseInsensitive)
            .replacingOccurrences(of: "\\u0026", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "\\u003A", with: ":", options: .caseInsensitive)
            .replacingOccurrences(of: "\\u003F", with: "?", options: .caseInsensitive)
            .replacingOccurrences(of: "\\u003D", with: "=", options: .caseInsensitive)
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&#38;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&#x26;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&#34;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&#x22;", with: "\"", options: .caseInsensitive)
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
