import Foundation

struct ExtractedHTMLMedia: Sendable {
    let rawURL: String
    let rawPosterURL: String?
    let title: String?
    let origin: HLSCandidateOrigin
    let kind: MediaCandidateKind
}

struct ExtractedHTMLFrame: Sendable {
    let rawURL: String?
    let sourceDocument: String?
    let title: String?
}

struct HTMLMediaExtraction: Sendable {
    let baseHref: String?
    let title: String?
    let rawThumbnailURL: String?
    let media: [ExtractedHTMLMedia]
    let frames: [ExtractedHTMLFrame]
}

enum HTMLMediaExtractor {
    private struct Tag {
        let name: String
        let attributes: [String: String]
        let isClosing: Bool
        let isSelfClosing: Bool
    }

    private struct VideoContext {
        let poster: String?
        let title: String?
    }

    static func extract(from html: String) -> HTMLMediaExtraction {
        var media: [ExtractedHTMLMedia] = []
        var frames: [ExtractedHTMLFrame] = []
        var videoStack: [VideoContext] = []
        var firstBaseHref: String?
        var sawBaseHref = false
        var pageTitle: String?
        var metadataTitle: String?
        var openGraphImage: String?
        var twitterImage: String?
        var looseFragments: [String] = []
        var cursor = html.startIndex

        while let opening = html[cursor...].firstIndex(of: "<") {
            if cursor < opening {
                looseFragments.append(String(html[cursor..<opening]))
            }
            if html[opening...].hasPrefix("<!--") {
                if let end = html.range(
                    of: "-->",
                    range: opening..<html.endIndex
                )?.upperBound {
                    cursor = end
                    continue
                }
                break
            }

            let bodyStart = html.index(after: opening)
            guard let closing = tagEnd(in: html, from: bodyStart) else { break }
            let body = html[bodyStart..<closing]
            cursor = html.index(after: closing)
            guard let tag = parseTag(body) else { continue }

            if tag.isClosing {
                if tag.name == "video", !videoStack.isEmpty {
                    videoStack.removeLast()
                }
                continue
            }

            // Retain the original source order for broad fallback discovery in
            // arbitrary attributes. Iframe attributes are deliberately
            // excluded: src/data-src are traversed as child documents below,
            // and srcdoc markup is parsed later with the correct frame depth.
            if tag.name != "iframe" {
                looseFragments.append(String(body))
            }

            if tag.name == "script" || tag.name == "style" {
                let closingPrefix = "</\(tag.name)"
                guard let closingRange = html.range(
                    of: closingPrefix,
                    options: [.caseInsensitive],
                    range: cursor..<html.endIndex
                ) else { break }
                if tag.name == "script" {
                    looseFragments.append(String(html[cursor..<closingRange.lowerBound]))
                }
                if let closingTagEnd = tagEnd(in: html, from: html.index(after: closingRange.lowerBound)) {
                    cursor = html.index(after: closingTagEnd)
                } else {
                    cursor = closingRange.upperBound
                }
                continue
            }

            if tag.name == "title", pageTitle == nil {
                if let closingRange = html.range(
                    of: "</title",
                    options: [.caseInsensitive],
                    range: cursor..<html.endIndex
                ) {
                    pageTitle = normalizedText(String(html[cursor..<closingRange.lowerBound]))
                    if let closingTagEnd = tagEnd(
                        in: html,
                        from: html.index(after: closingRange.lowerBound)
                    ) {
                        cursor = html.index(after: closingTagEnd)
                    } else {
                        cursor = closingRange.upperBound
                    }
                }
                continue
            }

            switch tag.name {
            case "base":
                if !sawBaseHref, let href = tag.attributes["href"] {
                    sawBaseHref = true
                    firstBaseHref = href
                }

            case "meta":
                let key = (tag.attributes["property"] ?? tag.attributes["name"] ?? "").lowercased()
                let content = nonempty(tag.attributes["content"])
                switch key {
                case "og:image", "og:image:url", "og:image:secure_url":
                    if openGraphImage == nil { openGraphImage = content }
                case "twitter:image", "twitter:image:src":
                    if twitterImage == nil { twitterImage = content }
                case "og:title", "twitter:title":
                    if metadataTitle == nil { metadataTitle = content.flatMap(normalizedText) }
                default:
                    break
                }

            case "video":
                let context = VideoContext(
                    poster: nonempty(tag.attributes["poster"] ?? tag.attributes["data-poster"]),
                    title: elementTitle(tag.attributes)
                )
                appendMediaReferences(
                    from: tag,
                    context: context,
                    origin: .video,
                    into: &media
                )
                if !tag.isSelfClosing { videoStack.append(context) }

            case "source":
                appendMediaReferences(
                    from: tag,
                    context: videoStack.last,
                    origin: .source,
                    into: &media
                )

            case "iframe":
                if let sourceDocument = tag.attributes["srcdoc"] {
                    frames.append(
                        ExtractedHTMLFrame(
                            rawURL: nil,
                            sourceDocument: sourceDocument,
                            title: elementTitle(tag.attributes)
                        )
                    )
                } else {
                    var seenFrameURLs = Set<String>()
                    for name in ["src", "data-src", "data-lazy-src", "data-url"] {
                        guard let rawURL = nonempty(tag.attributes[name]),
                              seenFrameURLs.insert(normalizedReferenceKey(rawURL)).inserted else {
                            continue
                        }
                        frames.append(
                            ExtractedHTMLFrame(
                                rawURL: rawURL,
                                sourceDocument: nil,
                                title: elementTitle(tag.attributes)
                            )
                        )
                    }
                }

            default:
                appendDataAttributeReferences(from: tag, into: &media)
            }
        }

        if cursor < html.endIndex {
            looseFragments.append(String(html[cursor...]))
        }

        var seenLoose = Set<String>()
        let structuredURLs = Set(media.map { normalizedReferenceKey($0.rawURL) })
        for reference in extractManifestStrings(from: looseFragments.joined(separator: "\n")) {
            let rawURL = reference.rawURL
            let key = normalizedReferenceKey(rawURL)
            guard !structuredURLs.contains(key), seenLoose.insert(key).inserted else { continue }
            media.append(
                ExtractedHTMLMedia(
                    rawURL: rawURL,
                    rawPosterURL: nil,
                    title: nil,
                    origin: .inlineScript,
                    kind: reference.kind
                )
            )
        }

        return HTMLMediaExtraction(
            baseHref: firstBaseHref,
            title: pageTitle ?? metadataTitle,
            rawThumbnailURL: openGraphImage ?? twitterImage,
            media: media,
            frames: frames
        )
    }

    static func extractM3U8Strings(from text: String) -> [String] {
        extractManifestStrings(from: text)
            .filter { $0.kind == .hls }
            .map(\.rawURL)
    }

    static func extractMPDStrings(from text: String) -> [String] {
        extractManifestStrings(from: text)
            .filter { $0.kind == .widevineDASH }
            .map(\.rawURL)
    }

    private static func extractManifestStrings(
        from text: String
    ) -> [(rawURL: String, kind: MediaCandidateKind)] {
        let decoded = URIResolver.decodeEscapes(decodeHTMLEntities(text))
        let supportedSuffixes = "m3u8|mpd|mp4|mov|m4v|m4a|mp3|aac|ac3|eac3|ec3|ogg|oga|opus|wav|flac|ts|m2t|m2ts|mts|webm"
        let pattern = #"(?i)((?:https?:)?//[^\s\"'<>\\]+?\.(?:"#
            + supportedSuffixes
            + #")(?:\?[^\s\"'<>\\]*)?|(?:\.\.?/|/)[^\s\"'<>\\]+?\.(?:"#
            + supportedSuffixes
            + #")(?:\?[^\s\"'<>\\]*)?|[A-Za-z0-9_%@+.-]+(?:/[A-Za-z0-9_%@+.,~!$&()*;=:-]+)*\.(?:"#
            + supportedSuffixes
            + #")(?:\?[^\s\"'<>\\]*)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(decoded.startIndex..<decoded.endIndex, in: decoded)
        var seen = Set<String>()
        var result: [(rawURL: String, kind: MediaCandidateKind)] = []

        for match in regex.matches(in: decoded, range: range) {
            guard let matchRange = Range(match.range(at: 1), in: decoded) else { continue }
            let raw = String(decoded[matchRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: "()[]{};,"))
            guard !raw.isEmpty,
                  let kind = manifestKind(for: raw, mimeType: nil),
                  seen.insert(normalizedReferenceKey(raw)).inserted else { continue }
            result.append((rawURL: raw, kind: kind))
        }
        return result
    }

    static func decodeHTMLEntities(_ value: String) -> String {
        var result = ""
        var cursor = value.startIndex

        while let ampersand = value[cursor...].firstIndex(of: "&") {
            result += value[cursor..<ampersand]
            let entityStart = value.index(after: ampersand)
            guard let semicolon = value[entityStart...].firstIndex(of: ";"),
                  value.distance(from: entityStart, to: semicolon) <= 16 else {
                result.append("&")
                cursor = entityStart
                continue
            }

            let name = String(value[entityStart..<semicolon])
            if let decoded = decodeEntity(name) {
                result += decoded
                cursor = value.index(after: semicolon)
            } else {
                result.append("&")
                cursor = entityStart
            }
        }
        result += value[cursor...]
        for entity in ["amp", "quot", "apos", "lt", "gt"] {
            result = result.replacingOccurrences(
                of: "(?i)&\(entity)(?=$|[^A-Za-z0-9])",
                with: decodeEntity(entity) ?? "",
                options: .regularExpression
            )
        }
        return result
    }

    private static func appendMediaReferences(
        from tag: Tag,
        context: VideoContext?,
        origin: HLSCandidateOrigin,
        into media: inout [ExtractedHTMLMedia]
    ) {
        let mimeType = tag.attributes["type"]?.lowercased()
        let poster = nonempty(
            tag.attributes["poster"]
                ?? tag.attributes["data-poster"]
                ?? context?.poster
        )
        let title = elementTitle(tag.attributes) ?? context?.title
        let names = [
            "src", "data-src", "data-hls-src", "data-dash-src", "data-mpd",
            "data-video-src", "data-playlist", "data-file", "data-url"
        ]
        var seen = Set<String>()

        for name in names {
            guard let rawURL = nonempty(tag.attributes[name]),
                  let kind = manifestKind(for: rawURL, mimeType: mimeType),
                  seen.insert(normalizedReferenceKey(rawURL)).inserted else { continue }
            media.append(
                ExtractedHTMLMedia(
                    rawURL: rawURL,
                    rawPosterURL: poster,
                    title: title,
                    origin: origin,
                    kind: kind
                )
            )
        }
    }

    private static func appendDataAttributeReferences(
        from tag: Tag,
        into media: inout [ExtractedHTMLMedia]
    ) {
        let interestingNames = [
            "data-hls", "data-hls-src", "data-dash-src", "data-mpd",
            "data-playlist", "data-file", "data-url"
        ]
        for name in interestingNames {
            guard let rawURL = nonempty(tag.attributes[name]),
                  let kind = manifestKind(for: rawURL, mimeType: nil) else {
                continue
            }
            media.append(
                ExtractedHTMLMedia(
                    rawURL: rawURL,
                    rawPosterURL: nonempty(tag.attributes["data-poster"]),
                    title: elementTitle(tag.attributes),
                    origin: .inlineScript,
                    kind: kind
                )
            )
        }
    }

    private static func manifestKind(
        for rawURL: String,
        mimeType: String?
    ) -> MediaCandidateKind? {
        if let mimeType = mimeType?.lowercased() {
            if mimeType.contains("application/dash+xml") {
                return .widevineDASH
            }
            if mimeType.contains("application/vnd.apple.mpegurl")
            || mimeType.contains("application/x-mpegurl")
            || mimeType.contains("application/mpegurl")
            || mimeType.contains("audio/mpegurl")
            || mimeType.contains("audio/x-mpegurl") {
                return .hls
            }
            if mimeType.hasPrefix("video/")
                || mimeType.hasPrefix("audio/")
                || mimeType.contains("application/ogg")
                || mimeType.contains("application/mp4") {
                return .progressive
            }
        }
        let decodedURL = URIResolver.decodeEscapes(rawURL)
        if decodedURL.range(
            of: #"\.m3u8(?:$|[?#])"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return .hls
        }
        if decodedURL.range(
            of: #"\.mpd(?:$|[?#])"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return .widevineDASH
        }
        if decodedURL.range(
            of: #"\.(?:mp4|mov|m4v|m4a|mp3|aac|ac3|eac3|ec3|ogg|oga|opus|wav|flac|ts|m2t|m2ts|mts|webm)(?:$|[?#])"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return .progressive
        }
        return nil
    }

    private static func parseTag(_ body: Substring) -> Tag? {
        var text = String(body)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("!"), !text.hasPrefix("?") else { return nil }

        var index = text.startIndex
        var isClosing = false
        if text[index] == "/" {
            isClosing = true
            index = text.index(after: index)
            skipWhitespace(in: text, index: &index)
        }

        let nameStart = index
        while index < text.endIndex, isNameCharacter(text[index]) {
            index = text.index(after: index)
        }
        guard nameStart < index else { return nil }
        let name = text[nameStart..<index].lowercased()
        let isSelfClosing = text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
        if isClosing {
            return Tag(name: name, attributes: [:], isClosing: true, isSelfClosing: false)
        }

        var attributes: [String: String] = [:]
        while index < text.endIndex {
            skipWhitespace(in: text, index: &index)
            guard index < text.endIndex, text[index] != "/" else { break }

            let attributeStart = index
            while index < text.endIndex, isAttributeNameCharacter(text[index]) {
                index = text.index(after: index)
            }
            guard attributeStart < index else {
                index = text.index(after: index)
                continue
            }
            let attributeName = text[attributeStart..<index].lowercased()
            skipWhitespace(in: text, index: &index)

            var value = ""
            if index < text.endIndex, text[index] == "=" {
                index = text.index(after: index)
                skipWhitespace(in: text, index: &index)
                if index < text.endIndex, text[index] == "\"" || text[index] == "'" {
                    let quote = text[index]
                    index = text.index(after: index)
                    let valueStart = index
                    while index < text.endIndex, text[index] != quote {
                        index = text.index(after: index)
                    }
                    value = String(text[valueStart..<index])
                    if index < text.endIndex { index = text.index(after: index) }
                } else {
                    let valueStart = index
                    while index < text.endIndex,
                          !isHTMLWhitespace(text[index]),
                          text[index] != ">" {
                        index = text.index(after: index)
                    }
                    value = String(text[valueStart..<index])
                    if isSelfClosing, value.hasSuffix("/") {
                        value.removeLast()
                    }
                }
            }

            if attributes[attributeName] == nil {
                attributes[attributeName] = decodeHTMLEntities(value)
            }
        }

        return Tag(
            name: name,
            attributes: attributes,
            isClosing: false,
            isSelfClosing: isSelfClosing
        )
    }

    private static func tagEnd(in html: String, from start: String.Index) -> String.Index? {
        var index = start
        var quote: Character?
        while index < html.endIndex {
            let character = html[index]
            if let currentQuote = quote {
                if character == currentQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = html.index(after: index)
        }
        return nil
    }

    private static func skipWhitespace(in text: String, index: inout String.Index) {
        while index < text.endIndex, isHTMLWhitespace(text[index]) {
            index = text.index(after: index)
        }
    }

    private static func isHTMLWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\r" || character == "\n" || character == "\u{000C}"
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == ":" || character == "-" || character == "_"
    }

    private static func isAttributeNameCharacter(_ character: Character) -> Bool {
        !isHTMLWhitespace(character) && character != "=" && character != "/" && character != ">"
    }

    private static func firstNonemptyAttribute(
        in attributes: [String: String],
        names: [String]
    ) -> String? {
        for name in names {
            if let value = nonempty(attributes[name]) { return value }
        }
        return nil
    }

    private static func elementTitle(_ attributes: [String: String]) -> String? {
        nonempty(attributes["title"] ?? attributes["aria-label"] ?? attributes["data-title"])
            .flatMap { normalizedText($0) }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedText(_ value: String) -> String? {
        let withoutTags = value.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        let decoded = decodeHTMLEntities(withoutTags)
        let collapsed = decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func normalizedReferenceKey(_ value: String) -> String {
        URIResolver.decodeEscapes(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntity(_ name: String) -> String? {
        switch name.lowercased() {
        case "amp": return "&"
        case "quot": return "\""
        case "apos": return "'"
        case "lt": return "<"
        case "gt": return ">"
        case "nbsp": return " "
        default:
            break
        }

        let value: UInt32?
        if name.lowercased().hasPrefix("#x") {
            value = UInt32(name.dropFirst(2), radix: 16)
        } else if name.hasPrefix("#") {
            value = UInt32(name.dropFirst(), radix: 10)
        } else {
            value = nil
        }
        guard let value,
              let scalar = UnicodeScalar(value),
              !(0xD800...0xDFFF).contains(value) else { return nil }
        return String(scalar)
    }
}
