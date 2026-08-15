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
