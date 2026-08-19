import Foundation

struct WidevineManifestDocument: Sendable {
    let sourceURL: URL
    let data: Data
}

struct WidevineLicenseConfiguration: Sendable {
    let serverURL: URL
    let httpHeaders: [String: String]
    let refererURL: URL?
    let observedRequestMetadata: WidevineLicenseRequestMetadata?

    init(
        serverURL: URL,
        httpHeaders: [String: String] = [:],
        refererURL: URL? = nil,
        observedRequestMetadata: WidevineLicenseRequestMetadata? = nil
    ) {
        self.serverURL = serverURL
        self.httpHeaders = httpHeaders
        self.refererURL = refererURL
        self.observedRequestMetadata = observedRequestMetadata
    }
}

extension WidevineLicenseConfiguration: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "WidevineLicenseConfiguration(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["contents": "<redacted>"], displayStyle: .struct)
    }
}

struct WidevineProcessingResult: Equatable, Sendable {
    /// A caller-owned temporary clear-media file. The service removes this
    /// file after validating and copying it into the protected export area.
    let mediaFileURL: URL
    /// The container selected from the actual DASH track plan. A plan with a
    /// video track remains MP4; a plan with audio only is decoded to PCM WAV.
    let outputFormat: MediaOutputFormat

    init(
        mediaFileURL: URL,
        outputFormat: MediaOutputFormat
    ) {
        self.mediaFileURL = mediaFileURL
        self.outputFormat = outputFormat
    }
}

/// Shared validation at both the Widevine provider boundary and immediately
/// before HLSDownloadService publishes the clear result. The result format is
/// never trusted solely because a provider returned a matching extension.
enum WidevineMediaOutputValidator {
    static func isValid(_ url: URL, format: MediaOutputFormat) -> Bool {
        guard url.isFileURL,
              let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize else {
            return false
        }

        switch format {
        case .mp4:
            return isValidMP4(url, fileSize: fileSize)
        case .wav:
            return isValidPCM16WAV(url, fileSize: fileSize)
        case .webm:
            guard let inspection = WebMMediaValidator.inspect(
                url,
                maximumBytes: Int64(fileSize)
            ) else { return false }
            return !inspection.isEncrypted
        }
    }

    private static func isValidMP4(_ url: URL, fileSize: Int) -> Bool {
        guard fileSize > 0 else { return false }
        return ISOBMFFClearMediaValidator.inspect(
            url,
            maximumBytes: Int64(fileSize),
            requireNonemptyMediaData: true,
            requireMovieTrack: true
        ) == .clear
    }

    private static func isValidPCM16WAV(_ url: URL, fileSize: Int) -> Bool {
        guard fileSize > 44,
              let file = BoundedMediaFile(url: url, maximumBytes: Int64(fileSize)),
              let header = file.read(at: 0, count: 12),
              ["RIFF", "RF64"].contains(ascii(header, at: 0)),
              ascii(header, at: 8) == "WAVE" else {
            return false
        }

        let isRF64 = ascii(header, at: 0) == "RF64"
        let riffSize32 = littleEndianUInt32(header, at: 4)
        if isRF64 {
            guard riffSize32 == UInt32.max else { return false }
        } else {
            guard riffSize32 != UInt32.max,
                  UInt64(riffSize32) <= UInt64.max - 8,
                  UInt64(riffSize32) + 8 == file.size else {
                return false
            }
        }

        var rf64RIFFSize: UInt64?
        var rf64DataSize: UInt64?
        var offset: UInt64 = 12
        var chunkCount = 0
        var foundPCMFormat = false
        var foundData = false
        while offset < file.size {
            guard file.size - offset >= 8,
                  let chunkHeader = file.read(at: offset, count: 8) else {
                return false
            }
            chunkCount += 1
            guard chunkCount <= 100_000 else { return false }

            let identifier = ascii(chunkHeader, at: 0)
            let rawDeclaredSize = littleEndianUInt32(chunkHeader, at: 4)
            let dataOffset = offset + 8
            let declaredSize: UInt64
            if isRF64, rawDeclaredSize == UInt32.max {
                guard identifier == "data", let rf64DataSize else { return false }
                declaredSize = rf64DataSize
            } else {
                declaredSize = UInt64(rawDeclaredSize)
            }
            guard declaredSize <= file.size - dataOffset else { return false }
            let dataEnd = dataOffset + declaredSize
            let paddedEnd = dataEnd + (declaredSize & 1)
            guard paddedEnd >= dataEnd, paddedEnd <= file.size else { return false }

            if identifier == "ds64" {
                guard isRF64,
                      rf64RIFFSize == nil,
                      rawDeclaredSize != UInt32.max,
                      declaredSize >= 28,
                      let ds64 = file.read(at: dataOffset, count: 28) else {
                    return false
                }
                let declaredRF64RIFFSize = littleEndianUInt64(ds64, at: 0)
                let declaredRF64DataSize = littleEndianUInt64(ds64, at: 8)
                let tableLength = UInt64(littleEndianUInt32(ds64, at: 24))
                guard declaredRF64RIFFSize <= UInt64.max - 8,
                      declaredRF64RIFFSize + 8 == file.size,
                      declaredRF64DataSize > 0,
                      tableLength <= (declaredSize - 28) / 12 else {
                    return false
                }
                rf64RIFFSize = declaredRF64RIFFSize
                rf64DataSize = declaredRF64DataSize
            } else if identifier == "fmt " {
                guard !foundPCMFormat,
                      declaredSize >= 16,
                      declaredSize <= UInt64(Int.max),
                      let format = file.read(
                        at: dataOffset,
                        count: min(Int(declaredSize), 40)
                      ) else {
                    return false
                }
                let formatTag = littleEndianUInt16(format, at: 0)
                let channels = littleEndianUInt16(format, at: 2)
                let sampleRate = littleEndianUInt32(format, at: 4)
                let bitsPerSample = littleEndianUInt16(format, at: 14)
                let plainPCM = formatTag == 0x0001
                let extensiblePCM: Bool
                if formatTag == 0xFFFE, declaredSize >= 40, format.count >= 40 {
                    let pcmSubformat = Data([
                        0x01, 0x00, 0x00, 0x00,
                        0x00, 0x00,
                        0x10, 0x00,
                        0x80, 0x00,
                        0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
                    ])
                    extensiblePCM = format.subdata(in: 24..<40) == pcmSubformat
                } else {
                    extensiblePCM = false
                }
                foundPCMFormat = (plainPCM || extensiblePCM)
                    && channels > 0
                    && sampleRate > 0
                    && bitsPerSample == 16
            } else if identifier == "data" {
                guard !foundData, declaredSize > 0 else { return false }
                foundData = true
            }
            offset = paddedEnd
        }
        return offset == file.size
            && (!isRF64 || rf64RIFFSize != nil)
            && foundPCMFormat
            && foundData
    }

    private static func ascii(_ data: Data, at offset: Int) -> String {
        guard offset >= 0, offset + 4 <= data.count else { return "" }
        return String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func littleEndianUInt64(_ data: Data, at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { return 0 }
        var value = UInt64.zero
        for index in 0..<8 {
            value |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        return value
    }
}

enum ProgressiveMediaProtectionStatus: Equatable, Sendable {
    case clear
    case encrypted
    case invalid
}

/// Fail-closed clear-input inspection performed before FFprobe/composition.
/// It parses container structure and never searches arbitrary `mdat`/block
/// payload bytes for strings, avoiding both false positives and marker-smuggle
/// bypasses.
enum ProgressiveMediaProtectionInspector {
    static func inspect(
        _ url: URL,
        container: MediaContainer,
        maximumBytes: Int64 = 8 * 1_024 * 1_024 * 1_024
    ) -> ProgressiveMediaProtectionStatus {
        switch container {
        case .isoBaseMedia:
            return ISOBMFFClearMediaValidator.inspect(url, maximumBytes: maximumBytes)
        case .webM:
            guard let result = WebMMediaValidator.inspect(url, maximumBytes: maximumBytes) else {
                return .invalid
            }
            return result.isEncrypted ? .encrypted : .clear
        case .transportStream, .aac, .ac3, .eac3:
            // Standalone SAMPLE-AES TS/AAC/AC-3 can retain clear framing and
            // track metadata. Without the HLS key declaration there is no
            // reliable structural proof that samples are clear.
            return .invalid
        case .mp3, .ogg, .wave, .flac:
            return .clear
        }
    }
}

private final class BoundedMediaFile {
    let size: UInt64
    private let handle: FileHandle

    init?(url: URL, maximumBytes: Int64) {
        guard maximumBytes > 0,
              url.isFileURL,
              let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              Int64(fileSize) <= maximumBytes,
              let handle = try? FileHandle(forReadingFrom: url),
              let actualSize = try? handle.seekToEnd(),
              actualSize == UInt64(fileSize) else {
            return nil
        }
        self.handle = handle
        size = actualSize
    }

    deinit { try? handle.close() }

    func read(at offset: UInt64, count: Int) -> Data? {
        guard count >= 0,
              offset <= size,
              UInt64(count) <= size - offset else { return nil }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}

private struct ISOBMFFBox {
    let type: String
    let payloadStart: UInt64
    let end: UInt64
}

private struct ISOBMFFClearMediaValidator {
    private static let maximumBoxes = 100_000
    private static let maximumDepth = 16
    private static let encryptedBoxTypes: Set<String> = [
        "pssh", "sinf", "tenc", "senc", "saiz", "saio", "sgpd", "sbgp",
        "ipro", "encv", "enca"
    ]
    private static let containerBoxTypes: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "mvex",
        "moof", "traf", "mfra", "udta", "schi"
    ]
    private let file: BoundedMediaFile
    private var boxCount = 0
    private var encrypted = false
    private var sawFileType = false
    private var sawMovie = false
    private var sawNonemptyMediaData = false
    private var sawNonemptyMovieTrack = false

    static func inspect(
        _ url: URL,
        maximumBytes: Int64,
        requireNonemptyMediaData: Bool = false,
        requireMovieTrack: Bool = false
    ) -> ProgressiveMediaProtectionStatus {
        guard let file = BoundedMediaFile(url: url, maximumBytes: maximumBytes) else {
            return .invalid
        }
        var scanner = Self(file: file)
        guard scanner.scanBoxes(from: 0, to: file.size, depth: 0),
              scanner.sawFileType,
              scanner.sawMovie,
              !requireNonemptyMediaData || scanner.sawNonemptyMediaData,
              !requireMovieTrack || scanner.sawNonemptyMovieTrack else {
            return .invalid
        }
        return scanner.encrypted ? .encrypted : .clear
    }

    private init(file: BoundedMediaFile) {
        self.file = file
    }

    private mutating func scanBoxes(
        from start: UInt64,
        to end: UInt64,
        depth: Int,
        parentType: String? = nil
    ) -> Bool {
        guard depth <= Self.maximumDepth else { return false }
        var cursor = start
        while cursor < end {
            guard let box = nextBox(at: cursor, parentEnd: end) else { return false }
            boxCount += 1
            guard boxCount <= Self.maximumBoxes else { return false }

            if depth == 0 {
                if box.type == "ftyp" {
                    guard box.end - box.payloadStart >= 8 else { return false }
                    sawFileType = true
                }
                if box.type == "moov" { sawMovie = true }
                if box.type == "mdat", box.end > box.payloadStart {
                    sawNonemptyMediaData = true
                }
            }
            if parentType == "moov",
               box.type == "trak",
               box.end > box.payloadStart {
                sawNonemptyMovieTrack = true
            }
            if Self.encryptedBoxTypes.contains(box.type) {
                encrypted = true
            }
            if box.type == "schm" {
                guard box.end - box.payloadStart >= 8,
                      let data = file.read(at: box.payloadStart + 4, count: 4) else {
                    return false
                }
                let scheme = String(decoding: data, as: UTF8.self).lowercased()
                if ["cenc", "cens", "cbc1", "cbcs"].contains(scheme) {
                    encrypted = true
                }
            } else if box.type == "uuid" {
                // PIFF uses UUID boxes for protection metadata, and an
                // unrecognized UUID payload cannot be proven unrelated to
                // sample encryption. Treat every structurally valid UUID box
                // as protected rather than allowing unknown schemes through.
                guard box.end - box.payloadStart >= 16 else { return false }
                encrypted = true
            } else if box.type == "stsd" {
                guard scanSampleDescription(box, depth: depth + 1) else { return false }
            } else if Self.containerBoxTypes.contains(box.type) {
                guard scanBoxes(
                    from: box.payloadStart,
                    to: box.end,
                    depth: depth + 1,
                    parentType: box.type
                ) else { return false }
            } else if box.type == "meta" {
                guard box.end - box.payloadStart >= 4,
                      scanBoxes(
                        from: box.payloadStart + 4,
                        to: box.end,
                        depth: depth + 1,
                        parentType: box.type
                      ) else { return false }
            }
            cursor = box.end
        }
        return cursor == end
    }

    private mutating func scanSampleDescription(_ box: ISOBMFFBox, depth: Int) -> Bool {
        guard depth <= Self.maximumDepth,
              box.end - box.payloadStart >= 8,
              let header = file.read(at: box.payloadStart, count: 8),
              header.prefix(4).allSatisfy({ $0 == 0 }) else {
            return false
        }
        let entryCount = Int(Self.uint32(header, at: 4))
        guard entryCount <= Self.maximumBoxes else { return false }
        var cursor = box.payloadStart + 8
        for _ in 0..<entryCount {
            guard let entry = nextBox(at: cursor, parentEnd: box.end) else { return false }
            boxCount += 1
            guard boxCount <= Self.maximumBoxes else { return false }
            if entry.type == "encv" || entry.type == "enca" { encrypted = true }
            cursor = entry.end
        }
        return cursor == box.end
    }

    private func nextBox(at offset: UInt64, parentEnd: UInt64) -> ISOBMFFBox? {
        guard offset <= parentEnd,
              parentEnd - offset >= 8,
              let header = file.read(at: offset, count: 8) else { return nil }
        let size32 = UInt64(Self.uint32(header, at: 0))
        let type = String(
            data: Data(header[4..<8]),
            encoding: .isoLatin1
        ) ?? ""
        let headerLength: UInt64
        let size: UInt64
        if size32 == 1 {
            guard parentEnd - offset >= 16,
                  let extended = file.read(at: offset + 8, count: 8) else { return nil }
            size = extended.reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
            headerLength = 16
        } else if size32 == 0 {
            size = parentEnd - offset
            headerLength = 8
        } else {
            size = size32
            headerLength = 8
        }
        guard size >= headerLength,
              size <= parentEnd - offset else { return nil }
        return ISOBMFFBox(
            type: type,
            payloadStart: offset + headerLength,
            end: offset + size
        )
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data[offset..<(offset + 4)].reduce(UInt32.zero) {
            ($0 << 8) | UInt32($1)
        }
    }
}

struct WebMMediaInspection: Equatable, Sendable {
    let isEncrypted: Bool
}

enum WebMMediaValidator {
    private struct Element {
        let identifier: UInt64
        let payloadStart: UInt64
        let end: UInt64
        let isUnknownSize: Bool
    }

    private static let ebmlIdentifier: UInt64 = 0x1A45DFA3
    private static let docTypeIdentifier: UInt64 = 0x4282
    private static let segmentIdentifier: UInt64 = 0x18538067
    private static let clusterIdentifier: UInt64 = 0x1F43B675
    private static let blockGroupIdentifier: UInt64 = 0xA0
    private static let encryptionIdentifier: UInt64 = 0x5035
    private static let encryptedBlockIdentifier: UInt64 = 0xAF
    private static let simpleBlockIdentifier: UInt64 = 0xA3
    private static let blockIdentifier: UInt64 = 0xA1
    private static let recursiveMasterIdentifiers: Set<UInt64> = [
        0x1F43B675, // Cluster (needed to inspect EncryptedBlock children)
        0xA0,       // BlockGroup
        0x1654AE6B, // Tracks
        0xAE,       // TrackEntry
        0x6D80,     // ContentEncodings
        0x6240      // ContentEncoding
    ]
    private static let maximumElements = 2_000_000
    private static let maximumDepth = 16

    static func inspect(
        _ url: URL,
        maximumBytes: Int64 = 8 * 1_024 * 1_024 * 1_024
    ) -> WebMMediaInspection? {
        guard let file = BoundedMediaFile(url: url, maximumBytes: maximumBytes),
              let header = element(at: 0, parentEnd: file.size, file: file),
              header.identifier == ebmlIdentifier,
              !header.isUnknownSize,
              header.payloadStart < header.end else { return nil }

        var cursor = header.payloadStart
        var docType: String?
        var headerElements = 0
        while cursor < header.end {
            guard let child = element(at: cursor, parentEnd: header.end, file: file),
                  child.end > cursor,
                  !child.isUnknownSize else { return nil }
            headerElements += 1
            guard headerElements <= maximumElements else { return nil }
            if child.identifier == docTypeIdentifier {
                let length = child.end - child.payloadStart
                guard length > 0, length <= 16,
                      let data = file.read(at: child.payloadStart, count: Int(length)) else {
                    return nil
                }
                docType = String(decoding: data, as: UTF8.self).lowercased()
            }
            cursor = child.end
        }
        guard cursor == header.end, docType == "webm" else { return nil }

        var topLevelCursor = header.end
        var segment: Element?
        while topLevelCursor < file.size {
            guard let topElement = element(
                at: topLevelCursor,
                parentEnd: file.size,
                file: file
            ), topElement.end > topLevelCursor else { return nil }
            if topElement.identifier == segmentIdentifier {
                guard segment == nil else { return nil }
                segment = topElement
            } else if topElement.identifier != 0xEC && topElement.identifier != 0xBF {
                return nil
            } else if topElement.isUnknownSize {
                return nil
            }
            topLevelCursor = topElement.end
        }
        guard topLevelCursor == file.size,
              let segment,
              segment.payloadStart < segment.end,
              segment.end == file.size else { return nil }

        var elementCount = 0
        var encrypted = false
        var sawMediaBlock = false
        guard scanMaster(
            from: segment.payloadStart,
            to: segment.end,
            depth: 0,
            parentIdentifier: segmentIdentifier,
            file: file,
            elementCount: &elementCount,
            encrypted: &encrypted,
            sawMediaBlock: &sawMediaBlock
        ), sawMediaBlock else { return nil }
        return WebMMediaInspection(isEncrypted: encrypted)
    }

    private static func scanMaster(
        from start: UInt64,
        to end: UInt64,
        depth: Int,
        parentIdentifier: UInt64,
        file: BoundedMediaFile,
        elementCount: inout Int,
        encrypted: inout Bool,
        sawMediaBlock: inout Bool
    ) -> Bool {
        guard depth <= maximumDepth else { return false }
        var cursor = start
        while cursor < end {
            guard let child = element(at: cursor, parentEnd: end, file: file),
                  child.end > cursor else { return false }
            elementCount += 1
            guard elementCount <= maximumElements else { return false }
            if child.isUnknownSize,
               !(child.identifier == clusterIdentifier
                    && parentIdentifier == segmentIdentifier) {
                return false
            }
            if child.identifier == simpleBlockIdentifier
                || child.identifier == encryptedBlockIdentifier {
                guard parentIdentifier == clusterIdentifier,
                      child.end - child.payloadStart >= 5 else { return false }
                sawMediaBlock = true
            } else if child.identifier == blockIdentifier {
                guard parentIdentifier == blockGroupIdentifier,
                      child.end - child.payloadStart >= 5 else { return false }
                sawMediaBlock = true
            }
            if child.identifier == encryptionIdentifier
                || child.identifier == encryptedBlockIdentifier {
                encrypted = true
            }
            if child.identifier == blockGroupIdentifier,
               parentIdentifier != clusterIdentifier {
                return false
            }
            if recursiveMasterIdentifiers.contains(child.identifier),
               !scanMaster(
                from: child.payloadStart,
                to: child.end,
                depth: depth + 1,
                parentIdentifier: child.identifier,
                file: file,
                elementCount: &elementCount,
                encrypted: &encrypted,
                sawMediaBlock: &sawMediaBlock
               ) {
                return false
            }
            cursor = child.end
        }
        return cursor == end
    }

    private static func element(
        at offset: UInt64,
        parentEnd: UInt64,
        file: BoundedMediaFile
    ) -> Element? {
        guard let identifier = variableInteger(
            at: offset,
            parentEnd: parentEnd,
            file: file,
            maximumLength: 4,
            retainMarker: true
        ) else { return nil }
        let sizeOffset = offset + UInt64(identifier.length)
        guard let size = variableInteger(
            at: sizeOffset,
            parentEnd: parentEnd,
            file: file,
            maximumLength: 8,
            retainMarker: false
        ) else { return nil }
        let payloadStart = sizeOffset + UInt64(size.length)
        guard payloadStart <= parentEnd else { return nil }
        let end: UInt64
        if size.isUnknown {
            end = parentEnd
        } else {
            guard size.value <= parentEnd - payloadStart else { return nil }
            end = payloadStart + size.value
        }
        return Element(
            identifier: identifier.value,
            payloadStart: payloadStart,
            end: end,
            isUnknownSize: size.isUnknown
        )
    }

    private static func variableInteger(
        at offset: UInt64,
        parentEnd: UInt64,
        file: BoundedMediaFile,
        maximumLength: Int,
        retainMarker: Bool
    ) -> (value: UInt64, length: Int, isUnknown: Bool)? {
        guard offset < parentEnd,
              let firstData = file.read(at: offset, count: 1),
              let first = firstData.first,
              first != 0 else { return nil }
        var mask: UInt8 = 0x80
        var length = 1
        while length <= 8, first & mask == 0 {
            mask >>= 1
            length += 1
        }
        guard length <= maximumLength,
              UInt64(length) <= parentEnd - offset,
              let data = file.read(at: offset, count: length) else { return nil }
        var value = UInt64(retainMarker ? first : first & ~mask)
        for byte in data.dropFirst() { value = (value << 8) | UInt64(byte) }
        let dataBits = 7 * length
        let unknownValue = dataBits == 64 ? UInt64.max : (UInt64(1) << UInt64(dataBits)) - 1
        return (value, length, !retainMarker && value == unknownValue)
    }
}

protocol WidevineProcessingProviding: Sendable {
    var isConfigured: Bool { get }

    func process(
        manifest: WidevineManifestDocument,
        licenseConfiguration: WidevineLicenseConfiguration,
        wvdData: Data
    ) async throws -> WidevineProcessingResult
}

extension WidevineProcessingProviding {
    var isConfigured: Bool { true }
}

enum WidevineProcessingError: LocalizedError, Equatable, Sendable {
    case unconfigured
    case domainNotAllowed
    case credentialMissing
    case licenseServerMissing
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .unconfigured:
            return "Widevine処理プロバイダが設定されていません。"
        case .domainNotAllowed:
            return "このWidevineコンテンツは許可ドメイン外のため再生・保存できません。"
        case .credentialMissing:
            return "Widevine L3のWVDファイルを先に読み込んでください。"
        case .licenseServerMissing:
            return "MPDからWidevineライセンスURLを確認できません。"
        case .invalidOutput:
            return "Widevine処理の出力ファイルを確認できません。"
        }
    }
}

struct UnconfiguredWidevineProcessingProvider: WidevineProcessingProviding, Sendable {
    let isConfigured = false

    func process(
        manifest: WidevineManifestDocument,
        licenseConfiguration: WidevineLicenseConfiguration,
        wvdData: Data
    ) async throws -> WidevineProcessingResult {
        throw WidevineProcessingError.unconfigured
    }
}

struct DomainRestrictedWidevineProcessingProvider: WidevineProcessingProviding, Sendable {
    private let base: any WidevineProcessingProviding

    init(base: any WidevineProcessingProviding) {
        self.base = base
    }

    var isConfigured: Bool { base.isConfigured }

    func process(
        manifest: WidevineManifestDocument,
        licenseConfiguration: WidevineLicenseConfiguration,
        wvdData: Data
    ) async throws -> WidevineProcessingResult {
        guard isDownloadableWidevineDomain(manifest.sourceURL),
              isDownloadableWidevineDomain(licenseConfiguration.serverURL) else {
            throw WidevineProcessingError.domainNotAllowed
        }
        return try await base.process(
            manifest: manifest,
            licenseConfiguration: licenseConfiguration,
            wvdData: wvdData
        )
    }
}
