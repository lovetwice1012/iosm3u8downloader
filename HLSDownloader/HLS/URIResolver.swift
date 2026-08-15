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
        try resolve(rawValue, relativeTo: baseURL, queryFallbackSource: baseURL)
    }

    static func resolve(
        _ rawValue: String,
        relativeTo baseURL: URL,
        queryFallbackSource: URL?
    ) throws -> URLCandidates {
        let primary = try resolveURL(rawValue, relativeTo: baseURL)

        var fallback: URL?
        if primary.query == nil,
           let queryFallbackSource,
           let baseQuery = URLComponents(
            url: queryFallbackSource,
            resolvingAgainstBaseURL: false
           )?.percentEncodedQuery,
           isSameOrigin(primary, queryFallbackSource),
           var components = URLComponents(url: primary, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = baseQuery
            fallback = components.url
        }

        return URLCandidates(primary: primary, sameOriginQueryFallback: fallback)
    }

    static func resolveURL(_ rawValue: String, relativeTo baseURL: URL) throws -> URL {
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
        return primary
    }

    static func decodeEscapes(_ value: String) -> String {
        var decoded = value
        for _ in 0..<2 {
            let next = decodeJavaScriptEscapePass(decoded)
            decoded = next
            if !next.contains("\\") { break }
        }
        return decoded
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&#38;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&#x26;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&#34;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&#x22;", with: "\"", options: .caseInsensitive)
    }

    private static func decodeJavaScriptEscapePass(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var result = ""
        var index = 0

        while index < scalars.count {
            guard scalars[index] == "\\", index + 1 < scalars.count else {
                result.unicodeScalars.append(scalars[index])
                index += 1
                continue
            }

            let marker = scalars[index + 1]
            if marker == "u", index + 5 < scalars.count,
               let first = hexValue(scalars[(index + 2)...(index + 5)]) {
                if (0xD800...0xDBFF).contains(first),
                   index + 11 < scalars.count,
                   scalars[index + 6] == "\\",
                   scalars[index + 7] == "u",
                   let second = hexValue(scalars[(index + 8)...(index + 11)]),
                   (0xDC00...0xDFFF).contains(second),
                   let scalar = UnicodeScalar(
                    0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                   ) {
                    result.unicodeScalars.append(scalar)
                    index += 12
                    continue
                }
                if let scalar = UnicodeScalar(first), !(0xD800...0xDFFF).contains(first) {
                    result.unicodeScalars.append(scalar)
                    index += 6
                    continue
                }
            } else if marker == "x", index + 3 < scalars.count,
                      let byte = hexValue(scalars[(index + 2)...(index + 3)]),
                      let scalar = UnicodeScalar(byte) {
                result.unicodeScalars.append(scalar)
                index += 4
                continue
            } else if marker == "/" || marker == "\\" || marker == "\"" || marker == "'" {
                result.unicodeScalars.append(marker)
                index += 2
                continue
            }

            result.unicodeScalars.append(scalars[index])
            index += 1
        }
        return result
    }

    private static func hexValue(_ scalars: ArraySlice<UnicodeScalar>) -> UInt32? {
        var text = ""
        for scalar in scalars {
            text.unicodeScalars.append(scalar)
        }
        return UInt32(text, radix: 16)
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
