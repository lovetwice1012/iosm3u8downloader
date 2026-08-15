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
        }
    }

    private static func isValidMP4(_ url: URL, fileSize: Int) -> Bool {
        guard fileSize >= 12,
              let header = readPrefix(url, maximumBytes: 12),
              header.count == 12,
              ascii(header, at: 4) == "ftyp" else {
            return false
        }
        let declaredSize = bigEndianUInt32(header, at: 0)
        return declaredSize >= 8 && UInt64(declaredSize) <= UInt64(fileSize)
    }

    private static func isValidPCM16WAV(_ url: URL, fileSize: Int) -> Bool {
        guard fileSize > 44,
              let prefix = readPrefix(url, maximumBytes: 1_048_576),
              prefix.count >= 44,
              ["RIFF", "RF64"].contains(ascii(prefix, at: 0)),
              ascii(prefix, at: 8) == "WAVE" else {
            return false
        }

        let isRF64 = ascii(prefix, at: 0) == "RF64"
        var rf64DataSize: UInt64?
        var offset = 12
        var foundPCMFormat = false
        var foundData = false
        while offset + 8 <= prefix.count {
            let identifier = ascii(prefix, at: offset)
            let rawDeclaredSize = littleEndianUInt32(prefix, at: offset + 4)
            let declaredSize = Int(rawDeclaredSize)
            let dataOffset = offset + 8
            if identifier == "ds64", isRF64, declaredSize >= 28,
               dataOffset + 28 <= prefix.count {
                let declaredRF64DataSize = littleEndianUInt64(prefix, at: dataOffset + 8)
                guard declaredRF64DataSize > 0 else { return false }
                rf64DataSize = declaredRF64DataSize
            } else if identifier == "fmt ", declaredSize >= 16,
               dataOffset + min(declaredSize, 40) <= prefix.count {
                let formatTag = littleEndianUInt16(prefix, at: dataOffset)
                let channels = littleEndianUInt16(prefix, at: dataOffset + 2)
                let sampleRate = littleEndianUInt32(prefix, at: dataOffset + 4)
                let bitsPerSample = littleEndianUInt16(prefix, at: dataOffset + 14)
                let plainPCM = formatTag == 0x0001
                let extensiblePCM: Bool
                if formatTag == 0xFFFE, declaredSize >= 40,
                   dataOffset + 40 <= prefix.count {
                    let pcmSubformat = Data([
                        0x01, 0x00, 0x00, 0x00,
                        0x00, 0x00,
                        0x10, 0x00,
                        0x80, 0x00,
                        0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
                    ])
                    extensiblePCM = prefix.subdata(
                        in: (dataOffset + 24)..<(dataOffset + 40)
                    ) == pcmSubformat
                } else {
                    extensiblePCM = false
                }
                foundPCMFormat = (plainPCM || extensiblePCM)
                    && channels > 0
                    && sampleRate > 0
                    && bitsPerSample == 16
            } else if identifier == "data" {
                // A declared non-empty chunk is insufficient: truncated WAVs
                // must never be published. RF64 carries the real 64-bit data
                // length in ds64 while the data chunk normally uses UInt32.max.
                let payloadSize: UInt64
                if isRF64, rawDeclaredSize == UInt32.max {
                    guard let rf64DataSize else { return false }
                    payloadSize = rf64DataSize
                } else {
                    payloadSize = UInt64(rawDeclaredSize)
                }
                guard payloadSize > 0,
                      dataOffset <= fileSize,
                      payloadSize <= UInt64(fileSize - dataOffset) else {
                    return false
                }
                foundData = true
                break
            }

            if declaredSize == Int(UInt32.max) { break }
            let paddedSize = declaredSize + (declaredSize & 1)
            guard paddedSize >= 0, dataOffset <= Int.max - paddedSize else {
                return false
            }
            offset = dataOffset + paddedSize
        }
        return foundPCMFormat && foundData
    }

    private static func readPrefix(_ url: URL, maximumBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maximumBytes)
    }

    private static func ascii(_ data: Data, at offset: Int) -> String {
        guard offset >= 0, offset + 4 <= data.count else { return "" }
        return String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data[offset..<(offset + 4)].reduce(UInt32.zero) {
            ($0 << 8) | UInt32($1)
        }
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
