import Foundation

enum PlaylistKind {
    case master(MasterPlaylist)
    case media(MediaPlaylist)
}

enum PlaylistParser {
    static func parse(text: String, effectiveURL: URL, requestReferer: URL? = nil) throws -> PlaylistKind {
        let normalized = normalize(text)
        guard normalized.hasPrefix("#EXTM3U") else {
            throw HLSError.invalidPlaylist("#EXTM3U がありません")
        }
        if normalized.components(separatedBy: .newlines).contains("#EXT-X-I-FRAMES-ONLY") {
            throw HLSError.invalidPlaylist("I-frame専用playlistは通常の動画として保存できません")
        }

        if normalized.contains("#EXT-X-STREAM-INF:") {
            return .master(try parseMaster(text: normalized, effectiveURL: effectiveURL))
        }
        return .media(try parseMedia(text: normalized, effectiveURL: effectiveURL, requestReferer: requestReferer))
    }

    static func isPlaylist(_ text: String) -> Bool {
        normalize(text).hasPrefix("#EXTM3U")
    }

    private static func parseMaster(text: String, effectiveURL: URL) throws -> MasterPlaylist {
        let lines = text.components(separatedBy: .newlines)
        var variants: [Variant] = []
        var renditions: [MediaRendition] = []
        var pendingVariantAttributes: [String: String]?

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingVariantAttributes = AttributeListParser.parse(value(afterColonIn: line))
                continue
            }

            if line.hasPrefix("#EXT-X-MEDIA:") {
                let attributes = AttributeListParser.parse(value(afterColonIn: line))
                guard let type = attributes["TYPE"],
                      let groupID = attributes["GROUP-ID"] else { continue }
                let url = try attributes["URI"].map { try URIResolver.resolve($0, relativeTo: effectiveURL) }
                renditions.append(
                    MediaRendition(
                        type: type.uppercased(),
                        groupID: groupID,
                        name: attributes["NAME"] ?? groupID,
                        url: url,
                        isDefault: isYes(attributes["DEFAULT"]),
                        isAutoSelect: isYes(attributes["AUTOSELECT"])
                    )
                )
                continue
            }

            if !line.hasPrefix("#"), let attributes = pendingVariantAttributes {
                let url = try URIResolver.resolve(line, relativeTo: effectiveURL)
                variants.append(
                    Variant(
                        url: url,
                        bandwidth: Int(attributes["BANDWIDTH"] ?? "0") ?? 0,
                        averageBandwidth: attributes["AVERAGE-BANDWIDTH"].flatMap(Int.init),
                        resolution: attributes["RESOLUTION"],
                        audioGroupID: attributes["AUDIO"]
                    )
                )
                pendingVariantAttributes = nil
            }
        }

        guard !variants.isEmpty else {
            throw HLSError.invalidPlaylist("画質variantがありません")
        }
        return MasterPlaylist(effectiveURL: effectiveURL, variants: variants, renditions: renditions)
    }

    private static func parseMedia(text: String, effectiveURL: URL, requestReferer: URL?) throws -> MediaPlaylist {
        let lines = text.components(separatedBy: .newlines)
        var segments: [MediaSegment] = []
        var mediaSequence: UInt64 = 0
        var pendingDuration: Double?
        var pendingByteRange: (length: Int64, offset: Int64?)?
        var previousByteRange: (url: URL, endOffset: Int64)?
        var currentEncryption: EncryptionDescriptor?
        var currentMap: InitializationMap?
        var pendingDiscontinuity = false
        var pendingGap = false
        var hasEndList = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                guard let parsedSequence = UInt64(value(afterColonIn: line)) else {
                    throw HLSError.invalidPlaylist("MEDIA-SEQUENCEが不正です")
                }
                mediaSequence = parsedSequence
            } else if line.hasPrefix("#EXTINF:") {
                let value = value(afterColonIn: line).split(separator: ",", maxSplits: 1).first.map(String.init) ?? "0"
                guard let duration = Double(value), duration.isFinite, duration >= 0 else {
                    throw HLSError.invalidPlaylist("EXTINFの長さが不正です")
                }
                pendingDuration = duration
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingByteRange = try parseByteRangeSpec(value(afterColonIn: line))
            } else if line.hasPrefix("#EXT-X-KEY:") {
                currentEncryption = try parseEncryption(line, effectiveURL: effectiveURL)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = AttributeListParser.parse(value(afterColonIn: line))
                guard let uri = attributes["URI"] else {
                    throw HLSError.invalidPlaylist("EXT-X-MAP にURIがありません")
                }
                let mapURL = try URIResolver.resolve(uri, relativeTo: effectiveURL)
                let range = try attributes["BYTERANGE"].map { spec -> ByteRange in
                    let parsed = try parseByteRangeSpec(spec)
                    guard let offset = parsed.offset else { throw HLSError.byteRangeInvalid }
                    return try makeByteRange(offset: offset, length: parsed.length)
                }
                if currentEncryption != nil && currentEncryption?.explicitIV == nil {
                    throw HLSError.invalidPlaylist("暗号化されたEXT-X-MAPには明示IVが必要です")
                }
                currentMap = InitializationMap(
                    url: mapURL,
                    byteRange: range,
                    encryption: currentEncryption
                )
            } else if line == "#EXT-X-DISCONTINUITY" {
                pendingDiscontinuity = true
            } else if line == "#EXT-X-GAP" {
                pendingGap = true
            } else if line == "#EXT-X-ENDLIST" {
                hasEndList = true
            } else if !line.hasPrefix("#") {
                if pendingGap { throw HLSError.gapUnsupported }
                guard let duration = pendingDuration else {
                    throw HLSError.invalidPlaylist("メディア断片の前にEXTINFがありません")
                }
                let candidates = try URIResolver.resolve(line, relativeTo: effectiveURL)
                let range: ByteRange?
                if let pendingByteRange {
                    let offset: Int64
                    if let explicitOffset = pendingByteRange.offset {
                        offset = explicitOffset
                    } else if let previousByteRange,
                              previousByteRange.url == candidates.primary {
                        offset = previousByteRange.endOffset
                    } else {
                        throw HLSError.byteRangeInvalid
                    }
                    let parsedRange = try makeByteRange(offset: offset, length: pendingByteRange.length)
                    range = parsedRange
                    previousByteRange = (candidates.primary, parsedRange.offset + parsedRange.length)
                } else {
                    range = nil
                    previousByteRange = nil
                }

                let (segmentSequence, sequenceOverflow) = mediaSequence.addingReportingOverflow(UInt64(segments.count))
                guard !sequenceOverflow else {
                    throw HLSError.invalidPlaylist("MEDIA-SEQUENCEが範囲外です")
                }
                segments.append(
                    MediaSegment(
                        ordinal: segments.count,
                        mediaSequence: segmentSequence,
                        duration: duration,
                        url: candidates,
                        byteRange: range,
                        encryption: currentEncryption,
                        initializationMap: currentMap,
                        hasDiscontinuity: pendingDiscontinuity
                    )
                )
                pendingDuration = nil
                pendingByteRange = nil
                pendingDiscontinuity = false
                pendingGap = false
            }
        }

        guard !segments.isEmpty else {
            throw HLSError.invalidPlaylist("メディア断片がありません")
        }
        return MediaPlaylist(
            effectiveURL: effectiveURL,
            requestReferer: requestReferer,
            segments: segments,
            hasEndList: hasEndList
        )
    }

    private static func parseEncryption(_ line: String, effectiveURL: URL) throws -> EncryptionDescriptor? {
        let attributes = AttributeListParser.parse(value(afterColonIn: line))
        let method = attributes["METHOD"]?.uppercased() ?? "NONE"
        if method == "NONE" { return nil }

        guard method == EncryptionDescriptor.Method.aes128.rawValue else {
            throw HLSError.drmUnsupported(method)
        }
        let keyFormat = attributes["KEYFORMAT"] ?? "identity"
        guard keyFormat.lowercased() == "identity" else {
            throw HLSError.drmUnsupported(keyFormat)
        }
        guard let uri = attributes["URI"] else {
            throw HLSError.invalidPlaylist("EXT-X-KEY にURIがありません")
        }
        return EncryptionDescriptor(
            method: .aes128,
            keyURL: try URIResolver.resolve(uri, relativeTo: effectiveURL),
            explicitIV: try attributes["IV"].map(parseIV)
        )
    }

    private static func parseIV(_ string: String) throws -> Data {
        var hex = string.lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard !hex.isEmpty, hex.count <= 32, hex.allSatisfy({ $0.isHexDigit }) else {
            throw HLSError.invalidPlaylist("AES IVが不正です")
        }
        hex = String(repeating: "0", count: 32 - hex.count) + hex
        var data = Data(capacity: 16)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw HLSError.invalidPlaylist("AES IVが不正です")
            }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func parseByteRangeSpec(_ value: String) throws -> (length: Int64, offset: Int64?) {
        let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let parts = unquoted
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard let first = parts.first, let length = Int64(first), length > 0 else {
            throw HLSError.byteRangeInvalid
        }
        let offset = parts.count == 2 ? Int64(parts[1]) : nil
        if parts.count == 2 && (offset == nil || offset! < 0) {
            throw HLSError.byteRangeInvalid
        }
        return (length, offset)
    }

    private static func makeByteRange(offset: Int64, length: Int64) throws -> ByteRange {
        guard offset >= 0, length > 0 else { throw HLSError.byteRangeInvalid }
        let (endOffset, overflow) = offset.addingReportingOverflow(length)
        guard !overflow, endOffset > offset else { throw HLSError.byteRangeInvalid }
        return ByteRange(offset: offset, length: length)
    }

    private static func value(afterColonIn line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return String(line[line.index(after: colon)...])
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
    }

    private static func isYes(_ value: String?) -> Bool {
        value?.uppercased() == "YES"
    }
}
