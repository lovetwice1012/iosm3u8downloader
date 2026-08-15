import Foundation
import Security

enum WidevineLicenseType: UInt64, Sendable {
    case streaming = 1
    case offline = 2
    case automatic = 3
}

enum WidevineContentKeyType: UInt64, Sendable {
    case signing = 1
    case content = 2
    case keyControl = 3
    case operatorSession = 4
    case entitlement = 5
    case oemContent = 6
}

struct WidevineContentKey: Equatable, Sendable {
    let id: Data
    let value: Data
    let type: WidevineContentKeyType
}

/// A signed Widevine license request. `requestData` is the exact byte string
/// that must be sent to the license server. Device private-key material is
/// deliberately not retained by this value.
struct WidevineLicenseChallenge: Sendable {
    let requestData: Data
    let licenseRequestData: Data
    let expectedKeyIDs: Set<Data>?
    let requestID: Data
}

extension WidevineLicenseChallenge: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "WidevineLicenseChallenge(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["contents": "<redacted>"], displayStyle: .struct)
    }
}

enum WidevineLicenseBodyEncoding: Equatable, Sendable {
    /// Sends the SignedMessage bytes without another envelope.
    case rawBinary
    /// Sends `{ "fieldName": "<base64 challenge>" }`.
    /// The field name must come from explicit service configuration; it must
    /// never be guessed from a captured body kind alone.
    case jsonBase64(fieldName: String)
    /// Sends `fieldName=<percent-encoded base64 challenge>`.
    /// The field name must come from explicit service configuration.
    case formURLEncodedBase64(fieldName: String)
}

/// Secret-bearing transport input. This type intentionally has no textual
/// description because headers and request bytes may contain credentials.
struct WidevineLicenseTransportRequest: Sendable {
    static let defaultMaximumResponseBytes = 16 * 1_024 * 1_024

    let serverURL: URL
    let requestData: Data
    let headers: [String: String]
    let contentType: String
    let referer: URL?
    let maximumResponseBytes: Int
    let bodyEncoding: WidevineLicenseBodyEncoding

    init(
        serverURL: URL,
        requestData: Data,
        headers: [String: String] = [:],
        contentType: String = "application/octet-stream",
        referer: URL? = nil,
        maximumResponseBytes: Int = defaultMaximumResponseBytes,
        bodyEncoding: WidevineLicenseBodyEncoding = .rawBinary
    ) {
        self.serverURL = serverURL
        self.requestData = requestData
        self.headers = headers
        self.contentType = contentType
        self.referer = referer
        self.maximumResponseBytes = maximumResponseBytes
        self.bodyEncoding = bodyEncoding
    }

    func encodedBody() throws -> Data {
        switch bodyEncoding {
        case .rawBinary:
            return requestData
        case let .jsonBase64(fieldName):
            try Self.validateWrapperFieldName(fieldName)
            return try JSONSerialization.data(
                withJSONObject: [fieldName: requestData.base64EncodedString()],
                options: []
            )
        case let .formURLEncodedBase64(fieldName):
            try Self.validateWrapperFieldName(fieldName)
            let encodedName = Self.formPercentEncode(fieldName)
            let encodedValue = Self.formPercentEncode(requestData.base64EncodedString())
            return Data("\(encodedName)=\(encodedValue)".utf8)
        }
    }

    private static func validateWrapperFieldName(_ fieldName: String) throws {
        guard !fieldName.isEmpty,
              fieldName.utf8.count <= 128,
              fieldName.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (value >= 0x30 && value <= 0x39)
                      || (value >= 0x41 && value <= 0x5A)
                      || (value >= 0x61 && value <= 0x7A)
                      || value == 0x2D
                      || value == 0x5F
              }) else {
            throw WidevineLicenseTransportError.invalidWrapperFieldName
        }
    }

    private static func formPercentEncode(_ value: String) -> String {
        let unreserved = Set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8
        )
        return value.utf8.map { byte in
            if unreserved.contains(byte) {
                return String(decoding: [byte], as: UTF8.self)
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}

extension WidevineLicenseTransportRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "WidevineLicenseTransportRequest(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["contents": "<redacted>"], displayStyle: .struct)
    }
}

protocol WidevineLicenseTransporting: Sendable {
    func send(_ request: WidevineLicenseTransportRequest) async throws -> Data
}

extension HTTPClient: WidevineLicenseTransporting {
    func send(_ request: WidevineLicenseTransportRequest) async throws -> Data {
        guard request.serverURL.scheme?.lowercased() == "https",
              request.serverURL.host != nil,
              request.serverURL.user == nil,
              request.serverURL.password == nil,
              request.maximumResponseBytes > 0,
              request.maximumResponseBytes <= WidevineLicenseTransportRequest.defaultMaximumResponseBytes,
              request.contentType.utf8.count <= 127,
              !request.contentType.isEmpty,
              !request.contentType.contains("\r"),
              !request.contentType.contains("\n"),
              !request.contentType.contains("\0") else {
            throw WidevineLicenseTransportError.invalidResponseLimit
        }
        var headers = request.headers.filter { name, _ in
            name.caseInsensitiveCompare("Content-Type") != .orderedSame
        }
        headers["Content-Type"] = request.contentType
        let payload = try await postLimited(
            request.serverURL,
            headers: headers,
            body: try request.encodedBody(),
            referer: request.referer,
            maximumResponseBytes: request.maximumResponseBytes
        )
        guard payload.data.count <= request.maximumResponseBytes else {
            throw WidevineLicenseTransportError.responseTooLarge
        }
        return payload.data
    }
}

enum WidevineLicenseTransportError: LocalizedError, Equatable, Sendable {
    case invalidWrapperFieldName
    case invalidResponseLimit
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidWrapperFieldName:
            return "Widevineライセンス要求のラッパー設定が正しくありません。"
        case .invalidResponseLimit:
            return "Widevineライセンス応答サイズの上限が正しくありません。"
        case .responseTooLarge:
            return "Widevineライセンス応答が許容サイズを超えています。"
        }
    }
}

enum WidevineL3ClientError: LocalizedError, Equatable, Sendable {
    case credentialTooLarge
    case invalidPrivateKey
    case invalidClientIdentification
    case credentialKeyMismatch
    case unsupportedPrivateKey
    case invalidPSSH
    case entropyFailure
    case requestSigningFailed
    case malformedResponse
    case unexpectedResponseType
    case licenseServerRejected
    case privacyModeUnsupported
    case unsupportedSessionKeyType
    case missingSessionKey
    case missingSignature
    case sessionKeyDecryptionFailed
    case invalidSessionKeyLength
    case responseAuthenticationFailed
    case malformedLicense
    case invalidEncryptedContentKey
    case contentKeyDecryptionFailed
    case unsupportedKeyType
    case unsupportedKeySecurityLevel
    case invalidContentKeyLength
    case duplicateKeyID
    case unexpectedKeyID
    case playbackNotAllowed
    case persistenceNotAllowed
    case unsupportedPolicyConstraint
    case unsupportedKeyConstraint
    case requestIDMismatch
    case licenseTypeMismatch
    case expiredLicense
    case noContentKeys

    var errorDescription: String? {
        switch self {
        case .credentialTooLarge:
            return "WVD資格情報が許容サイズを超えています。"
        case .invalidPrivateKey:
            return "WVDのデバイス秘密鍵を読み込めませんでした。"
        case .invalidClientIdentification:
            return "WVDのclient identificationを確認できませんでした。"
        case .credentialKeyMismatch:
            return "WVDのclient certificateとRSA秘密鍵が一致しません。"
        case .unsupportedPrivateKey:
            return "WVDのRSA秘密鍵形式または鍵長に対応していません。"
        case .invalidPSSH:
            return "Widevine PSSHデータが正しくありません。"
        case .entropyFailure:
            return "Widevine要求に必要な乱数を生成できませんでした。"
        case .requestSigningFailed:
            return "Widevineライセンス要求に署名できませんでした。"
        case .malformedResponse:
            return "Widevineライセンス応答の形式が正しくありません。"
        case .unexpectedResponseType:
            return "Widevineライセンス応答のメッセージ種別が正しくありません。"
        case .licenseServerRejected:
            return "Widevineライセンスサーバーが要求を拒否しました。"
        case .privacyModeUnsupported:
            return "Widevine privacy mode／service certificateにはまだ対応していません。"
        case .unsupportedSessionKeyType:
            return "Widevineライセンス応答のセッション鍵方式に対応していません。"
        case .missingSessionKey:
            return "Widevineライセンス応答にセッション鍵がありません。"
        case .missingSignature:
            return "Widevineライセンス応答に認証値がありません。"
        case .sessionKeyDecryptionFailed:
            return "Widevineセッション鍵を復号できませんでした。"
        case .invalidSessionKeyLength:
            return "Widevineセッション鍵の長さが正しくありません。"
        case .responseAuthenticationFailed:
            return "Widevineライセンス応答の認証に失敗しました。"
        case .malformedLicense:
            return "Widevineライセンス本体の形式が正しくありません。"
        case .invalidEncryptedContentKey:
            return "Widevineコンテンツ鍵の暗号化形式が正しくありません。"
        case .contentKeyDecryptionFailed:
            return "Widevineコンテンツ鍵を復号できませんでした。"
        case .unsupportedKeyType:
            return "Widevineライセンスに未対応の鍵種別が含まれています。"
        case .unsupportedKeySecurityLevel:
            return "このWidevine鍵にはL3より高い保護レベルが必要です。"
        case .invalidContentKeyLength:
            return "Widevineコンテンツ鍵またはKIDの長さが正しくありません。"
        case .duplicateKeyID:
            return "Widevineライセンスに重複したKIDが含まれています。"
        case .unexpectedKeyID:
            return "Widevineライセンスに要求していないKIDが含まれています。"
        case .playbackNotAllowed:
            return "Widevineライセンスでは再生が許可されていません。"
        case .persistenceNotAllowed:
            return "Widevineライセンスではオフライン保存が許可されていません。"
        case .unsupportedPolicyConstraint:
            return "このWidevineライセンスには復号済み保存で強制できないポリシー制約があります。"
        case .unsupportedKeyConstraint:
            return "このWidevineコンテンツ鍵には復号済み保存で強制できない保護制約があります。"
        case .requestIDMismatch:
            return "Widevineライセンス応答が送信した要求と一致しません。"
        case .licenseTypeMismatch:
            return "Widevineライセンス応答がオフライン保存用ではありません。"
        case .expiredLicense:
            return "Widevineライセンスの有効期限が切れています。"
        case .noContentKeys:
            return "Widevineライセンスに利用可能なコンテンツ鍵がありません。"
        }
    }
}

enum WidevineL3KeyAcquirerError: LocalizedError, Equatable, Sendable {
    case missingInitData
    case insecureLicenseURL
    case unsafeWrapperInference
    case invalidResponseEnvelope
    case invalidExpectedKeyID
    case duplicateKeyID
    case unexpectedKeyID
    case missingExpectedKey

    var errorDescription: String? {
        switch self {
        case .missingInitData:
            return "Widevine PSSHデータがありません。"
        case .insecureLicenseURL:
            return "Widevineライセンス通信には安全なHTTPS URLが必要です。"
        case .unsafeWrapperInference:
            return "観測情報だけではWidevineライセンス要求のラッパー形式を安全に確定できません。"
        case .invalidResponseEnvelope:
            return "Widevineライセンス応答のラッパー形式を確認できません。"
        case .invalidExpectedKeyID:
            return "MPDのWidevine KIDが正しくありません。"
        case .duplicateKeyID:
            return "Widevineライセンス応答に重複したKIDが含まれています。"
        case .unexpectedKeyID:
            return "Widevineライセンス応答に要求していないKIDが含まれています。"
        case .missingExpectedKey:
            return "Widevineライセンス応答に必要なコンテンツ鍵がありません。"
        }
    }
}

/// Bridges the protocol-only L3 client into the DASH provider. JSON and form
/// wrappers require an explicit field name at construction time; observed
/// body metadata never contains enough information to reconstruct them.
struct WidevineL3KeyAcquirer: WidevineKeyAcquiring, Sendable {
    let isConfigured = true

    private let transport: any WidevineLicenseTransporting
    private let explicitBodyEncoding: WidevineLicenseBodyEncoding?
    private let maximumResponseBytes: Int

    init(
        transport: any WidevineLicenseTransporting,
        bodyEncoding: WidevineLicenseBodyEncoding? = nil,
        maximumResponseBytes: Int = WidevineLicenseTransportRequest.defaultMaximumResponseBytes
    ) {
        self.transport = transport
        explicitBodyEncoding = bodyEncoding
        self.maximumResponseBytes = maximumResponseBytes
    }

    func acquireKeys(
        initData: [Data],
        expectedKeyIDs: Set<String>,
        licenseConfiguration: WidevineLicenseConfiguration,
        wvdData: Data
    ) async throws -> [WidevineContentKey] {
        guard !initData.isEmpty else {
            throw WidevineL3KeyAcquirerError.missingInitData
        }
        guard isDownloadableWidevineDomain(licenseConfiguration.serverURL) else {
            throw WidevineL3KeyAcquirerError.insecureLicenseURL
        }
        var expectedIDs = Set<Data>()
        expectedIDs.reserveCapacity(expectedKeyIDs.count)
        for value in expectedKeyIDs {
            expectedIDs.insert(try Self.keyIDData(value))
        }
        let encoding = try resolvedEncoding(from: licenseConfiguration.observedRequestMetadata)
        let contentType = resolvedContentType(
            encoding: encoding,
            metadata: licenseConfiguration.observedRequestMetadata,
            headers: licenseConfiguration.httpHeaders
        )
        let client = try WidevineL3Client(wvdData: wvdData)

        var keysByID: [Data: WidevineContentKey] = [:]
        for pssh in initData {
            try Task.checkCancellation()
            let challenge = try client.makeLicenseChallenge(
                psshData: pssh,
                licenseType: .offline
            )
            let wrappedResponse = try await transport.send(
                WidevineLicenseTransportRequest(
                    serverURL: licenseConfiguration.serverURL,
                    requestData: challenge.requestData,
                    headers: licenseConfiguration.httpHeaders,
                    contentType: contentType,
                    referer: licenseConfiguration.refererURL,
                    maximumResponseBytes: maximumResponseBytes,
                    bodyEncoding: encoding
                )
            )
            let response = try WidevineLicenseResponseEnvelope.unwrap(wrappedResponse)
            let keys = try client.parseLicense(response, for: challenge)
            for key in keys {
                if !expectedIDs.isEmpty, !expectedIDs.contains(key.id) {
                    throw WidevineL3KeyAcquirerError.unexpectedKeyID
                }
                if let existing = keysByID[key.id] {
                    guard existing == key else {
                        throw WidevineL3KeyAcquirerError.duplicateKeyID
                    }
                    continue
                }
                keysByID[key.id] = key
            }
        }
        guard expectedIDs.isSubset(of: Set(keysByID.keys)) else {
            throw WidevineL3KeyAcquirerError.missingExpectedKey
        }
        return keysByID.values.sorted { $0.id.lexicographicallyPrecedes($1.id) }
    }

    private func resolvedEncoding(
        from metadata: WidevineLicenseRequestMetadata?
    ) throws -> WidevineLicenseBodyEncoding {
        if let explicitBodyEncoding { return explicitBodyEncoding }
        guard let metadata else { return .rawBinary }
        switch metadata.bodyKind {
        case .none, .binary:
            return .rawBinary
        case .json, .formURLEncoded, .text, .unknown:
            throw WidevineL3KeyAcquirerError.unsafeWrapperInference
        }
    }

    private func resolvedContentType(
        encoding: WidevineLicenseBodyEncoding,
        metadata: WidevineLicenseRequestMetadata?,
        headers: [String: String]
    ) -> String {
        if let header = headers.first(where: {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value {
            return header
        }
        if let contentType = metadata?.contentType { return contentType }
        switch encoding {
        case .rawBinary:
            return "application/octet-stream"
        case .jsonBase64:
            return "application/json"
        case .formURLEncodedBase64:
            return "application/x-www-form-urlencoded"
        }
    }

    private static func keyIDData(_ value: String) throws -> Data {
        guard let uuid = UUID(uuidString: value) else {
            throw WidevineL3KeyAcquirerError.invalidExpectedKeyID
        }
        var bytes = uuid.uuid
        return withUnsafeBytes(of: &bytes) { Data($0) }
    }
}

enum WidevineLicenseResponseEnvelope {
    private static let jsonFieldNames = Set([
        "license", "licenseData", "license_data",
        "signedMessage", "signed_message", "response"
    ])

    static func unwrap(_ data: Data) throws -> Data {
        guard !data.isEmpty,
              data.count <= WidevineLicenseTransportRequest.defaultMaximumResponseBytes else {
            throw WidevineL3KeyAcquirerError.invalidResponseEnvelope
        }
        if isRecognizedSignedMessage(data) { return data }

        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let decoded = decodeBase64License(trimmed) { return decoded }
        }

        guard let json = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else {
            throw WidevineL3KeyAcquirerError.invalidResponseEnvelope
        }
        let candidates: [String]
        if let value = json as? String {
            candidates = [value]
        } else if let object = json as? [String: Any] {
            candidates = object.compactMap { key, value in
                guard jsonFieldNames.contains(key) else { return nil }
                return value as? String
            }
        } else {
            throw WidevineL3KeyAcquirerError.invalidResponseEnvelope
        }
        guard candidates.count == 1,
              let value = candidates.first,
              let license = decodeBase64License(
                value.trimmingCharacters(in: .whitespacesAndNewlines)
              ) else {
            throw WidevineL3KeyAcquirerError.invalidResponseEnvelope
        }
        return license
    }

    private static func decodeBase64License(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.utf8.count <= WidevineLicenseTransportRequest.defaultMaximumResponseBytes * 2,
              let decoded = Data(base64Encoded: value),
              isRecognizedSignedMessage(decoded) else {
            return nil
        }
        return decoded
    }

    private static func isRecognizedSignedMessage(_ data: Data) -> Bool {
        guard let message = try? WidevineSignedMessage.parse(data),
              let type = message.type else { return false }
        switch type {
        case 2:
            return message.message != nil
                && message.signature != nil
                && message.sessionKey != nil
        case 3, 4, 5:
            return true
        default:
            return false
        }
    }
}

final class WidevineL3Client: @unchecked Sendable {
    typealias Clock = @Sendable () -> Int64
    typealias RandomBytes = @Sendable (Int) throws -> Data

    private static let maximumWVDBytes = 256 * 1_024
    private static let maximumPSSHBytes = 2 * 1_024 * 1_024
    private static let minimumRSABytes = 256
    private static let maximumRSABytes = 512
    static let supportsPrivacyMode = false

    private let clientIdentification: Data
    private let privateKey: SecKey
    private let deviceType: WVDFileDeviceType
    private let clock: Clock
    private let randomBytes: RandomBytes

    init(
        wvdData: Data,
        clock: @escaping Clock = { Int64(Date().timeIntervalSince1970) },
        randomBytes: @escaping RandomBytes = WidevineL3Client.secureRandomBytes
    ) throws {
        guard wvdData.count <= Self.maximumWVDBytes else {
            throw WidevineL3ClientError.credentialTooLarge
        }
        let metadata = try WVDFileValidator().validate(wvdData)
        let fields = try Self.parseWVDFields(wvdData)
        let privateKey = try Self.makePrivateKey(from: fields.privateKey)
        let keySize = SecKeyGetBlockSize(privateKey)
        guard keySize >= Self.minimumRSABytes, keySize <= Self.maximumRSABytes else {
            throw WidevineL3ClientError.unsupportedPrivateKey
        }
        try Self.validateClientIdentification(
            fields.clientIdentification,
            matches: privateKey
        )

        self.clientIdentification = fields.clientIdentification
        self.privateKey = privateKey
        self.deviceType = metadata.deviceType
        self.clock = clock
        self.randomBytes = randomBytes
    }

    func makeLicenseChallenge(
        psshData: Data,
        licenseType: WidevineLicenseType = .offline
    ) throws -> WidevineLicenseChallenge {
        let payload = try WidevinePSSH.payload(from: psshData, maximumBytes: Self.maximumPSSHBytes)
        let expectedKeyIDs = try WidevinePSSH.keyIDs(fromPayload: payload)
        let requestID = try makeRequestID()
        let nonceBytes = try randomBytes(4)
        guard nonceBytes.count == 4 else {
            throw WidevineL3ClientError.entropyFailure
        }
        var nonce = nonceBytes.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        } & 0x7FFF_FFFF
        if nonce == 0 { nonce = 1 }

        var pssh = WidevineProtobufWriter()
        pssh.appendBytes(field: 1, value: payload)
        pssh.appendVarint(field: 2, value: licenseType.rawValue)
        pssh.appendBytes(field: 3, value: requestID)

        var contentIdentification = WidevineProtobufWriter()
        contentIdentification.appendMessage(field: 1, value: pssh.data)

        var request = WidevineProtobufWriter()
        request.appendMessage(field: 1, value: clientIdentification)
        request.appendMessage(field: 2, value: contentIdentification.data)
        request.appendVarint(field: 3, value: 1) // LicenseRequest.NEW
        request.appendVarint(field: 4, value: UInt64(max(clock(), 0)))
        request.appendVarint(field: 6, value: 21) // VERSION_2_1
        request.appendVarint(field: 7, value: UInt64(nonce))

        let requestData = request.data
        guard SecKeyIsAlgorithmSupported(privateKey, .sign, .rsaSignatureMessagePSSSHA1) else {
            throw WidevineL3ClientError.unsupportedPrivateKey
        }
        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePSSSHA1,
            requestData as CFData,
            &signingError
        ) as Data? else {
            throw WidevineL3ClientError.requestSigningFailed
        }

        var signedMessage = WidevineProtobufWriter()
        signedMessage.appendVarint(field: 1, value: 1) // SignedMessage.LICENSE_REQUEST
        signedMessage.appendBytes(field: 2, value: requestData)
        signedMessage.appendBytes(field: 3, value: signature)
        return WidevineLicenseChallenge(
            requestData: signedMessage.data,
            licenseRequestData: requestData,
            expectedKeyIDs: expectedKeyIDs,
            requestID: requestID
        )
    }

    func parseLicense(
        _ response: Data,
        for challenge: WidevineLicenseChallenge
    ) throws -> [WidevineContentKey] {
        let signedMessage: WidevineSignedMessage
        do {
            signedMessage = try WidevineSignedMessage.parse(response)
        } catch {
            throw WidevineL3ClientError.malformedResponse
        }

        if signedMessage.type == 5 || signedMessage.type == 4 {
            throw WidevineL3ClientError.privacyModeUnsupported
        }
        if signedMessage.type == 3 {
            throw WidevineL3ClientError.licenseServerRejected
        }
        guard signedMessage.type == 2 else {
            throw WidevineL3ClientError.unexpectedResponseType
        }
        guard signedMessage.remoteAttestation == nil else {
            throw WidevineL3ClientError.privacyModeUnsupported
        }
        guard signedMessage.sessionKeyType == nil || signedMessage.sessionKeyType == 1 else {
            throw WidevineL3ClientError.unsupportedSessionKeyType
        }
        guard let encryptedSessionKey = signedMessage.sessionKey,
              !encryptedSessionKey.isEmpty else {
            throw WidevineL3ClientError.missingSessionKey
        }
        guard let signature = signedMessage.signature,
              !signature.isEmpty else {
            throw WidevineL3ClientError.missingSignature
        }
        guard signature.count == Int(CC_SHA256_DIGEST_LENGTH) else {
            throw WidevineL3ClientError.responseAuthenticationFailed
        }
        guard let licenseData = signedMessage.message else {
            throw WidevineL3ClientError.malformedResponse
        }

        guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, .rsaEncryptionOAEPSHA1) else {
            throw WidevineL3ClientError.unsupportedPrivateKey
        }
        var decryptionError: Unmanaged<CFError>?
        guard let decryptedSessionKey = SecKeyCreateDecryptedData(
            privateKey,
            .rsaEncryptionOAEPSHA1,
            encryptedSessionKey as CFData,
            &decryptionError
        ) as Data? else {
            throw WidevineL3ClientError.sessionKeyDecryptionFailed
        }
        guard decryptedSessionKey.count == kCCKeySizeAES128 else {
            throw WidevineL3ClientError.invalidSessionKeyLength
        }

        let encryptionKey: Data
        let authenticationKey: Data
        do {
            encryptionKey = try WidevineL3Crypto.deriveEncryptionKey(
                request: challenge.licenseRequestData,
                sessionKey: decryptedSessionKey
            )
            authenticationKey = try WidevineL3Crypto.deriveAuthenticationKey(
                request: challenge.licenseRequestData,
                sessionKey: decryptedSessionKey
            )
        } catch {
            throw WidevineL3ClientError.malformedResponse
        }

        var authenticatedMessage = Data()
        if let coreMessage = signedMessage.oemcryptoCoreMessage {
            authenticatedMessage.append(coreMessage)
        }
        authenticatedMessage.append(licenseData)
        let expectedSignature = WidevineL3Crypto.hmacSHA256(
            key: authenticationKey,
            message: authenticatedMessage
        )
        guard WidevineL3Crypto.constantTimeEqual(signature, expectedSignature) else {
            throw WidevineL3ClientError.responseAuthenticationFailed
        }

        let license: WidevineLicenseMessage
        do {
            license = try WidevineLicenseMessage.parse(licenseData)
        } catch {
            throw WidevineL3ClientError.malformedLicense
        }
        guard license.identification?.requestID == challenge.requestID else {
            throw WidevineL3ClientError.requestIDMismatch
        }
        guard license.identification?.licenseType == WidevineLicenseType.offline.rawValue else {
            throw WidevineL3ClientError.licenseTypeMismatch
        }
        guard !license.hasUnsupportedConstraint else {
            throw WidevineL3ClientError.unsupportedPolicyConstraint
        }
        try validatePolicy(license.policy, licenseStartTime: license.licenseStartTime)

        var keys: [WidevineContentKey] = []
        var seenKeyIDs = Set<Data>()
        keys.reserveCapacity(license.keys.count)
        for encryptedKey in license.keys {
            guard let keyType = WidevineContentKeyType(rawValue: encryptedKey.type) else {
                throw WidevineL3ClientError.unsupportedKeyType
            }
            guard keyType == .content else {
                if keyType == .keyControl {
                    throw WidevineL3ClientError.unsupportedKeyConstraint
                }
                throw WidevineL3ClientError.unsupportedKeyType
            }
            guard !encryptedKey.hasUnsupportedConstraint else {
                throw WidevineL3ClientError.unsupportedKeyConstraint
            }
            guard encryptedKey.securityLevel == 1 else {
                throw WidevineL3ClientError.unsupportedKeySecurityLevel
            }
            guard let keyID = encryptedKey.id, keyID.count == 16 else {
                throw WidevineL3ClientError.invalidContentKeyLength
            }
            guard seenKeyIDs.insert(keyID).inserted else {
                throw WidevineL3ClientError.duplicateKeyID
            }
            if let expectedKeyIDs = challenge.expectedKeyIDs,
               !expectedKeyIDs.contains(keyID) {
                throw WidevineL3ClientError.unexpectedKeyID
            }
            guard let iv = encryptedKey.iv,
                  let ciphertext = encryptedKey.key,
                  iv.count == kCCBlockSizeAES128,
                  !ciphertext.isEmpty,
                  ciphertext.count.isMultiple(of: kCCBlockSizeAES128) else {
                throw WidevineL3ClientError.invalidEncryptedContentKey
            }
            let value: Data
            do {
                value = try WidevineL3Crypto.decryptAESCBCPKCS7(
                    ciphertext,
                    key: encryptionKey,
                    iv: iv
                )
            } catch {
                throw WidevineL3ClientError.contentKeyDecryptionFailed
            }
            guard value.count == 16 else {
                throw WidevineL3ClientError.invalidContentKeyLength
            }
            keys.append(
                WidevineContentKey(
                    id: keyID,
                    value: value,
                    type: keyType
                )
            )
        }
        guard !keys.isEmpty else {
            throw WidevineL3ClientError.noContentKeys
        }
        return keys
    }

    private func validatePolicy(
        _ policy: WidevineLicensePolicy?,
        licenseStartTime: UInt64?
    ) throws {
        guard let policy, policy.canPlay else {
            throw WidevineL3ClientError.playbackNotAllowed
        }
        guard policy.canPersist else {
            throw WidevineL3ClientError.persistenceNotAllowed
        }
        guard !policy.canRenew,
              !policy.hasUnsupportedConstraint,
              (policy.rentalDurationSeconds ?? 0) == 0,
              (policy.playbackDurationSeconds ?? 0) == 0,
              (policy.licenseDurationSeconds ?? 0) == 0 else {
            // A clear MP4 cannot enforce expiry/renewal after export. Only an
            // explicitly persistent, unbounded export license is accepted.
            throw WidevineL3ClientError.unsupportedPolicyConstraint
        }
        if let licenseStartTime, licenseStartTime > UInt64(Int64.max) {
            throw WidevineL3ClientError.expiredLicense
        }
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw WidevineL3ClientError.entropyFailure
        }
        return Data(bytes)
    }

    private static func validateClientIdentification(
        _ clientIdentification: Data,
        matches privateKey: SecKey
    ) throws {
        let certificatePublicKeyData: Data
        do {
            var clientReader = try WidevineProtobufReader(clientIdentification)
            var signedCertificate: Data?
            while let field = try clientReader.next() {
                guard field.number == 1 else { continue }
                guard field.wireType == 2,
                      signedCertificate == nil,
                      let value = field.bytes else {
                    throw WidevineL3ClientError.invalidClientIdentification
                }
                signedCertificate = value
            }
            guard let signedCertificate else {
                throw WidevineL3ClientError.invalidClientIdentification
            }

            var signedReader = try WidevineProtobufReader(signedCertificate)
            var certificate: Data?
            while let field = try signedReader.next() {
                guard field.number == 1 else { continue }
                guard field.wireType == 2,
                      certificate == nil,
                      let value = field.bytes else {
                    throw WidevineL3ClientError.invalidClientIdentification
                }
                certificate = value
            }
            guard let certificate else {
                throw WidevineL3ClientError.invalidClientIdentification
            }

            var certificateReader = try WidevineProtobufReader(certificate)
            var publicKeyData: Data?
            while let field = try certificateReader.next() {
                guard field.number == 5 else { continue }
                guard field.wireType == 2,
                      publicKeyData == nil,
                      let value = field.bytes,
                      !value.isEmpty else {
                    throw WidevineL3ClientError.invalidClientIdentification
                }
                publicKeyData = value
            }
            guard let publicKeyData else {
                throw WidevineL3ClientError.invalidClientIdentification
            }
            certificatePublicKeyData = publicKeyData
        } catch let error as WidevineL3ClientError {
            throw error
        } catch {
            throw WidevineL3ClientError.invalidClientIdentification
        }

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ]
        var importError: Unmanaged<CFError>?
        guard let certificatePublicKey = SecKeyCreateWithData(
            certificatePublicKeyData as CFData,
            attributes as CFDictionary,
            &importError
        ),
              let derivedPublicKey = SecKeyCopyPublicKey(privateKey) else {
            throw WidevineL3ClientError.invalidClientIdentification
        }
        var certificateExportError: Unmanaged<CFError>?
        var derivedExportError: Unmanaged<CFError>?
        guard let certificateExternal = SecKeyCopyExternalRepresentation(
            certificatePublicKey,
            &certificateExportError
        ) as Data?,
              let derivedExternal = SecKeyCopyExternalRepresentation(
                derivedPublicKey,
                &derivedExportError
              ) as Data? else {
            throw WidevineL3ClientError.invalidClientIdentification
        }
        guard WidevineL3Crypto.constantTimeEqual(
            certificateExternal,
            derivedExternal
        ) else {
            throw WidevineL3ClientError.credentialKeyMismatch
        }
    }

    private func makeRequestID() throws -> Data {
        switch deviceType {
        case .chrome:
            let value = try randomBytes(16)
            guard value.count == 16 else { throw WidevineL3ClientError.entropyFailure }
            return value
        case .android:
            let randomPrefix = try randomBytes(4)
            guard randomPrefix.count == 4 else {
                throw WidevineL3ClientError.entropyFailure
            }
            var binary = Data()
            binary.append(randomPrefix)
            binary.append(Data(repeating: 0, count: 4))
            var sessionNumber = UInt64(1).littleEndian
            withUnsafeBytes(of: &sessionNumber) { binary.append(contentsOf: $0) }
            let hexadecimal = binary.map { String(format: "%02X", $0) }.joined()
            return Data(hexadecimal.utf8)
        }
    }

    private static func parseWVDFields(_ data: Data) throws -> (
        privateKey: Data,
        clientIdentification: Data
    ) {
        let bytes = [UInt8](data)
        var cursor = 7

        func readField() throws -> Data {
            guard cursor <= bytes.count, bytes.count - cursor >= 2 else {
                throw WidevineL3ClientError.invalidPrivateKey
            }
            let length = (Int(bytes[cursor]) << 8) | Int(bytes[cursor + 1])
            cursor += 2
            guard length > 0,
                  cursor <= bytes.count,
                  length <= bytes.count - cursor else {
                throw WidevineL3ClientError.invalidPrivateKey
            }
            let field = Data(bytes[cursor..<(cursor + length)])
            cursor += length
            return field
        }

        let privateKey = try readField()
        let clientIdentification = try readField()
        guard cursor == bytes.count else {
            throw WidevineL3ClientError.invalidPrivateKey
        }
        return (privateKey, clientIdentification)
    }

    private static func makePrivateKey(from encodedKey: Data) throws -> SecKey {
        if let key = createRSAKey(encodedKey) {
            return key
        }
        if let unwrapped = try? WidevineDER.pkcs1PrivateKey(fromPKCS8: encodedKey),
           let key = createRSAKey(unwrapped) {
            return key
        }
        throw WidevineL3ClientError.invalidPrivateKey
    }

    private static func createRSAKey(_ data: Data) -> SecKey? {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &error)
    }
}

// MARK: - Minimal protobuf codec

struct WidevineProtobufWriter {
    private(set) var data = Data()

    mutating func appendVarint(field: Int, value: UInt64) {
        appendKey(field: field, wireType: 0)
        appendRawVarint(value)
    }

    mutating func appendBytes(field: Int, value: Data) {
        appendKey(field: field, wireType: 2)
        appendRawVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func appendMessage(field: Int, value: Data) {
        appendBytes(field: field, value: value)
    }

    private mutating func appendKey(field: Int, wireType: UInt64) {
        precondition(field > 0)
        appendRawVarint((UInt64(field) << 3) | wireType)
    }

    private mutating func appendRawVarint(_ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }
}

struct WidevineProtobufField {
    let number: Int
    let wireType: UInt8
    let varint: UInt64?
    let bytes: Data?
}

struct WidevineProtobufReader {
    private static let maximumMessageBytes = 16 * 1_024 * 1_024
    private let bytes: [UInt8]
    private var cursor = 0

    init(_ data: Data) throws {
        guard data.count <= Self.maximumMessageBytes else {
            throw WidevineL3ClientError.malformedResponse
        }
        bytes = [UInt8](data)
    }

    mutating func next() throws -> WidevineProtobufField? {
        guard cursor < bytes.count else { return nil }
        let key = try readVarint()
        let rawFieldNumber = key >> 3
        guard rawFieldNumber <= UInt64(Int.max) else {
            throw WidevineL3ClientError.malformedResponse
        }
        let fieldNumber = Int(rawFieldNumber)
        let wireType = UInt8(key & 0x07)
        guard fieldNumber > 0 else { throw WidevineL3ClientError.malformedResponse }

        switch wireType {
        case 0:
            return WidevineProtobufField(
                number: fieldNumber,
                wireType: wireType,
                varint: try readVarint(),
                bytes: nil
            )
        case 1:
            try skip(8)
        case 2:
            let rawLength = try readVarint()
            guard rawLength <= UInt64(Int.max) else {
                throw WidevineL3ClientError.malformedResponse
            }
            let length = Int(rawLength)
            guard cursor <= bytes.count, length <= bytes.count - cursor else {
                throw WidevineL3ClientError.malformedResponse
            }
            let value = Data(bytes[cursor..<(cursor + length)])
            cursor += length
            return WidevineProtobufField(
                number: fieldNumber,
                wireType: wireType,
                varint: nil,
                bytes: value
            )
        case 5:
            try skip(4)
        default:
            throw WidevineL3ClientError.malformedResponse
        }
        return WidevineProtobufField(
            number: fieldNumber,
            wireType: wireType,
            varint: nil,
            bytes: nil
        )
    }

    private mutating func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard cursor < bytes.count else {
                throw WidevineL3ClientError.malformedResponse
            }
            let byte = bytes[cursor]
            cursor += 1
            if shift == 63, byte > 1 {
                throw WidevineL3ClientError.malformedResponse
            }
            value |= UInt64(byte & 0x7F) << UInt64(shift)
            if byte & 0x80 == 0 { return value }
        }
        throw WidevineL3ClientError.malformedResponse
    }

    private mutating func skip(_ count: Int) throws {
        guard count >= 0, cursor <= bytes.count, count <= bytes.count - cursor else {
            throw WidevineL3ClientError.malformedResponse
        }
        cursor += count
    }
}

struct WidevineSignedMessage {
    let type: UInt64?
    let message: Data?
    let signature: Data?
    let sessionKey: Data?
    let sessionKeyType: UInt64?
    let remoteAttestation: Data?
    let oemcryptoCoreMessage: Data?

    static func parse(_ data: Data) throws -> WidevineSignedMessage {
        var reader = try WidevineProtobufReader(data)
        var type: UInt64?
        var message: Data?
        var signature: Data?
        var sessionKey: Data?
        var sessionKeyType: UInt64?
        var remoteAttestation: Data?
        var oemcryptoCoreMessage: Data?

        while let field = try reader.next() {
            switch field.number {
            case 1:
                guard field.wireType == 0, type == nil else {
                    throw WidevineL3ClientError.malformedResponse
                }
                type = field.varint
            case 2:
                guard field.wireType == 2, message == nil else {
                    throw WidevineL3ClientError.malformedResponse
                }
                message = field.bytes
            case 3:
                guard field.wireType == 2, signature == nil else {
                    throw WidevineL3ClientError.malformedResponse
                }
                signature = field.bytes
            case 4:
                guard field.wireType == 2, sessionKey == nil else {
                    throw WidevineL3ClientError.malformedResponse
                }
                sessionKey = field.bytes
            case 5:
                guard field.wireType == 2, remoteAttestation == nil else {
                    throw WidevineL3ClientError.malformedResponse
                }
                remoteAttestation = field.bytes
            case 8:
                guard field.wireType == 0, sessionKeyType == nil else {
                    throw WidevineL3ClientError.malformedResponse
                }
                sessionKeyType = field.varint
            case 9:
                guard field.wireType == 2, oemcryptoCoreMessage == nil else {
                    throw WidevineL3ClientError.malformedResponse
                }
                oemcryptoCoreMessage = field.bytes
            default:
                continue
            }
        }
        return WidevineSignedMessage(
            type: type,
            message: message,
            signature: signature,
            sessionKey: sessionKey,
            sessionKeyType: sessionKeyType,
            remoteAttestation: remoteAttestation,
            oemcryptoCoreMessage: oemcryptoCoreMessage
        )
    }
}

struct WidevineEncryptedKey {
    let id: Data?
    let iv: Data?
    let key: Data?
    let type: UInt64
    let securityLevel: UInt64
    let hasUnsupportedConstraint: Bool
}

struct WidevineLicenseIdentification {
    let requestID: Data?
    let licenseType: UInt64
}

struct WidevineLicensePolicy {
    let canPlay: Bool
    let canPersist: Bool
    let canRenew: Bool
    let rentalDurationSeconds: UInt64?
    let playbackDurationSeconds: UInt64?
    let licenseDurationSeconds: UInt64?
    let hasUnsupportedConstraint: Bool
}

struct WidevineLicenseMessage {
    let keys: [WidevineEncryptedKey]
    let identification: WidevineLicenseIdentification?
    let policy: WidevineLicensePolicy?
    let licenseStartTime: UInt64?
    let hasUnsupportedConstraint: Bool

    static func parse(_ data: Data) throws -> WidevineLicenseMessage {
        var reader = try WidevineProtobufReader(data)
        var keys: [WidevineEncryptedKey] = []
        var identification: WidevineLicenseIdentification?
        var policy: WidevineLicensePolicy?
        var licenseStartTime: UInt64?
        var hasUnsupportedConstraint = false
        while let field = try reader.next() {
            switch field.number {
            case 1:
                guard field.wireType == 2,
                      identification == nil,
                      let encodedIdentification = field.bytes else {
                    throw WidevineL3ClientError.malformedLicense
                }
                identification = try parseIdentification(encodedIdentification)
            case 2:
                guard field.wireType == 2,
                      policy == nil,
                      let encodedPolicy = field.bytes else {
                    throw WidevineL3ClientError.malformedLicense
                }
                policy = try parsePolicy(encodedPolicy)
            case 3:
                guard field.wireType == 2, let encodedKey = field.bytes else {
                    throw WidevineL3ClientError.malformedLicense
                }
                keys.append(try parseKey(encodedKey))
            case 4:
                guard field.wireType == 0,
                      licenseStartTime == nil,
                      let value = field.varint else {
                    throw WidevineL3ClientError.malformedLicense
                }
                licenseStartTime = value
            case 6:
                guard field.wireType == 2 else {
                    throw WidevineL3ClientError.malformedLicense
                }
            case 7:
                guard field.wireType == 0 else {
                    throw WidevineL3ClientError.malformedLicense
                }
            case 11:
                guard field.wireType == 2 else {
                    throw WidevineL3ClientError.malformedLicense
                }
            case 5, 8, 9, 10:
                // Remote-attestation, HDCP SRM and platform-verification
                // requirements cannot be enforced by a clear-file exporter.
                hasUnsupportedConstraint = true
            default:
                // Future root-level license restrictions are fail-closed.
                hasUnsupportedConstraint = true
            }
        }
        return WidevineLicenseMessage(
            keys: keys,
            identification: identification,
            policy: policy,
            licenseStartTime: licenseStartTime,
            hasUnsupportedConstraint: hasUnsupportedConstraint
        )
    }

    private static func parseKey(_ data: Data) throws -> WidevineEncryptedKey {
        var reader = try WidevineProtobufReader(data)
        var id: Data?
        var iv: Data?
        var key: Data?
        var type: UInt64 = 1 // proto2 default is the first enum value, SIGNING
        var sawType = false
        var securityLevel: UInt64 = 1 // SW_SECURE_CRYPTO
        var sawSecurityLevel = false
        var hasUnsupportedConstraint = false

        while let field = try reader.next() {
            switch field.number {
            case 1:
                guard field.wireType == 2, id == nil else {
                    throw WidevineL3ClientError.malformedLicense
                }
                id = field.bytes
            case 2:
                guard field.wireType == 2, iv == nil else {
                    throw WidevineL3ClientError.malformedLicense
                }
                iv = field.bytes
            case 3:
                guard field.wireType == 2, key == nil else {
                    throw WidevineL3ClientError.malformedLicense
                }
                key = field.bytes
            case 4:
                guard field.wireType == 0, !sawType, let rawType = field.varint else {
                    throw WidevineL3ClientError.malformedLicense
                }
                type = rawType
                sawType = true
            case 5:
                guard field.wireType == 0,
                      !sawSecurityLevel,
                      let rawLevel = field.varint else {
                    throw WidevineL3ClientError.malformedLicense
                }
                securityLevel = rawLevel
                sawSecurityLevel = true
            case 6, 7, 8, 9, 10, 11:
                // Output protection, key control, operator permissions,
                // resolution constraints, and anti-rollback cannot be
                // enforced once a clear MP4 is exported.
                hasUnsupportedConstraint = true
            case 12:
                guard field.wireType == 2 else {
                    throw WidevineL3ClientError.malformedLicense
                }
            default:
                // Fail closed for future key-container constraints.
                hasUnsupportedConstraint = true
            }
        }
        return WidevineEncryptedKey(
            id: id,
            iv: iv,
            key: key,
            type: type,
            securityLevel: securityLevel,
            hasUnsupportedConstraint: hasUnsupportedConstraint
        )
    }

    private static func parseIdentification(_ data: Data) throws -> WidevineLicenseIdentification {
        var reader = try WidevineProtobufReader(data)
        var requestID: Data?
        var licenseType: UInt64 = WidevineLicenseType.streaming.rawValue
        var sawLicenseType = false
        while let field = try reader.next() {
            switch field.number {
            case 1:
                guard field.wireType == 2, requestID == nil else {
                    throw WidevineL3ClientError.malformedLicense
                }
                requestID = field.bytes
            case 4:
                guard field.wireType == 0,
                      !sawLicenseType,
                      let value = field.varint else {
                    throw WidevineL3ClientError.malformedLicense
                }
                licenseType = value
                sawLicenseType = true
            default:
                continue
            }
        }
        return WidevineLicenseIdentification(
            requestID: requestID,
            licenseType: licenseType
        )
    }

    private static func parsePolicy(_ data: Data) throws -> WidevineLicensePolicy {
        var reader = try WidevineProtobufReader(data)
        var canPlay: Bool?
        var canPersist: Bool?
        var canRenew: Bool?
        var rentalDurationSeconds: UInt64?
        var playbackDurationSeconds: UInt64?
        var licenseDurationSeconds: UInt64?
        var hasUnsupportedConstraint = false
        while let field = try reader.next() {
            switch field.number {
            case 1:
                guard field.wireType == 0,
                      canPlay == nil,
                      let value = field.varint,
                      value <= 1 else {
                    throw WidevineL3ClientError.malformedLicense
                }
                canPlay = value == 1
            case 2:
                guard field.wireType == 0,
                      canPersist == nil,
                      let value = field.varint,
                      value <= 1 else {
                    throw WidevineL3ClientError.malformedLicense
                }
                canPersist = value == 1
            case 3:
                guard field.wireType == 0,
                      canRenew == nil,
                      let value = field.varint,
                      value <= 1 else {
                    throw WidevineL3ClientError.malformedLicense
                }
                canRenew = value == 1
            case 4:
                guard field.wireType == 0,
                      rentalDurationSeconds == nil,
                      let value = field.varint else {
                    throw WidevineL3ClientError.malformedLicense
                }
                rentalDurationSeconds = value
            case 5:
                guard field.wireType == 0,
                      playbackDurationSeconds == nil,
                      let value = field.varint else {
                    throw WidevineL3ClientError.malformedLicense
                }
                playbackDurationSeconds = value
            case 6:
                guard field.wireType == 0,
                      licenseDurationSeconds == nil,
                      let value = field.varint else {
                    throw WidevineL3ClientError.malformedLicense
                }
                licenseDurationSeconds = value
            case 7...15:
                // Renewal, grace, and soft-enforcement policy fields cannot
                // be carried over to a clear exported file.
                hasUnsupportedConstraint = true
            default:
                hasUnsupportedConstraint = true
            }
        }
        return WidevineLicensePolicy(
            canPlay: canPlay ?? false,
            canPersist: canPersist ?? false,
            canRenew: canRenew ?? false,
            rentalDurationSeconds: rentalDurationSeconds,
            playbackDurationSeconds: playbackDurationSeconds,
            licenseDurationSeconds: licenseDurationSeconds,
            hasUnsupportedConstraint: hasUnsupportedConstraint
        )
    }
}

// MARK: - Cryptography

enum WidevineL3Crypto {
    static func deriveEncryptionKey(request: Data, sessionKey: Data) throws -> Data {
        guard sessionKey.count == kCCKeySizeAES128 else {
            throw WidevineL3ClientError.invalidSessionKeyLength
        }
        var input = Data([0x01])
        input.append(Data("ENCRYPTION".utf8))
        input.append(0x00)
        input.append(request)
        input.append(contentsOf: [0x00, 0x00, 0x00, 0x80])
        return try aesCMAC(message: input, key: sessionKey)
    }

    static func deriveAuthenticationKey(request: Data, sessionKey: Data) throws -> Data {
        guard sessionKey.count == kCCKeySizeAES128 else {
            throw WidevineL3ClientError.invalidSessionKeyLength
        }
        var base = Data([0x01])
        base.append(Data("AUTHENTICATION".utf8))
        base.append(0x00)
        base.append(request)
        base.append(contentsOf: [0x00, 0x00, 0x02, 0x00])
        let first = try aesCMAC(message: base, key: sessionKey)
        base[base.startIndex] = 0x02
        let second = try aesCMAC(message: base, key: sessionKey)
        return first + second
    }

    static func aesCMAC(message: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else {
            throw WidevineL3ClientError.invalidSessionKeyLength
        }
        let zero = Data(repeating: 0, count: kCCBlockSizeAES128)
        let l = try encryptAESECBBlock(zero, key: key)
        let firstSubkey = cmacDouble(l)
        let secondSubkey = cmacDouble(firstSubkey)

        let blockSize = kCCBlockSizeAES128
        let blockCount = max(1, (message.count + blockSize - 1) / blockSize)
        let hasCompleteLastBlock = !message.isEmpty && message.count.isMultiple(of: blockSize)
        var lastBlock: Data
        if hasCompleteLastBlock {
            let start = (blockCount - 1) * blockSize
            lastBlock = Data(message[start..<(start + blockSize)])
            xorInPlace(&lastBlock, with: firstSubkey)
        } else {
            let start = (blockCount - 1) * blockSize
            let suffix = start < message.count ? Data(message[start..<message.count]) : Data()
            lastBlock = suffix
            lastBlock.append(0x80)
            if lastBlock.count < blockSize {
                lastBlock.append(Data(repeating: 0, count: blockSize - lastBlock.count))
            }
            xorInPlace(&lastBlock, with: secondSubkey)
        }

        var state = Data(repeating: 0, count: blockSize)
        if blockCount > 1 {
            for blockIndex in 0..<(blockCount - 1) {
                let start = blockIndex * blockSize
                var block = Data(message[start..<(start + blockSize)])
                xorInPlace(&block, with: state)
                state = try encryptAESECBBlock(block, key: key)
            }
        }
        xorInPlace(&lastBlock, with: state)
        return try encryptAESECBBlock(lastBlock, key: key)
    }

    static func hmacSHA256(key: Data, message: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { digestBytes in
            key.withUnsafeBytes { keyBytes in
                message.withUnsafeBytes { messageBytes in
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA256),
                        keyBytes.baseAddress,
                        key.count,
                        messageBytes.baseAddress,
                        message.count,
                        digestBytes.baseAddress
                    )
                }
            }
        }
        return Data(digest)
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        let left = [UInt8](lhs)
        let right = [UInt8](rhs)
        var difference = UInt64(left.count ^ right.count)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= UInt64(leftByte ^ rightByte)
        }
        return difference == 0
    }

    static func decryptAESCBCPKCS7(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128,
              iv.count == kCCBlockSizeAES128,
              !ciphertext.isEmpty,
              ciphertext.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw WidevineL3ClientError.invalidEncryptedContentKey
        }
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { cipherBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress,
                            ciphertext.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw WidevineL3ClientError.contentKeyDecryptionFailed
        }
        output.removeSubrange(outputLength..<output.count)
        return output
    }

    static func encryptAESCBCPKCS7(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            throw WidevineL3ClientError.invalidEncryptedContentKey
        }
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            plaintext.withUnsafeBytes { plaintextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            plaintextBytes.baseAddress,
                            plaintext.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw WidevineL3ClientError.contentKeyDecryptionFailed
        }
        output.removeSubrange(outputLength..<output.count)
        return output
    }

    private static func encryptAESECBBlock(_ block: Data, key: Data) throws -> Data {
        guard block.count == kCCBlockSizeAES128, key.count == kCCKeySizeAES128 else {
            throw WidevineL3ClientError.malformedResponse
        }
        var output = Data(count: kCCBlockSizeAES128)
        var outputLength = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            block.withUnsafeBytes { blockBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        blockBytes.baseAddress,
                        block.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess, outputLength == kCCBlockSizeAES128 else {
            throw WidevineL3ClientError.malformedResponse
        }
        return output
    }

    private static func cmacDouble(_ block: Data) -> Data {
        let input = [UInt8](block)
        var output = [UInt8](repeating: 0, count: input.count)
        var carry: UInt8 = 0
        for index in stride(from: input.count - 1, through: 0, by: -1) {
            let byte = input[index]
            output[index] = (byte << 1) | carry
            carry = (byte & 0x80) == 0 ? 0 : 1
        }
        if carry != 0 {
            output[output.count - 1] ^= 0x87
        }
        return Data(output)
    }

    private static func xorInPlace(_ value: inout Data, with mask: Data) {
        precondition(value.count == mask.count)
        for offset in 0..<value.count {
            let index = value.index(value.startIndex, offsetBy: offset)
            let maskIndex = mask.index(mask.startIndex, offsetBy: offset)
            value[index] ^= mask[maskIndex]
        }
    }
}

// MARK: - PSSH and DER parsing

enum WidevinePSSH {
    private static let systemID: [UInt8] = [
        0xED, 0xEF, 0x8B, 0xA9, 0x79, 0xD6, 0x4A, 0xCE,
        0xA3, 0xC8, 0x27, 0xDC, 0xD5, 0x1D, 0x21, 0xED
    ]

    static func payload(from input: Data, maximumBytes: Int) throws -> Data {
        guard !input.isEmpty, input.count <= maximumBytes else {
            throw WidevineL3ClientError.invalidPSSH
        }
        let bytes = [UInt8](input)
        let looksLikeBox = bytes.count >= 8
            && bytes[4] == 0x70 && bytes[5] == 0x73
            && bytes[6] == 0x73 && bytes[7] == 0x68
        guard looksLikeBox else { return input }

        var cursor = 0
        let size32 = try readUInt32(bytes, cursor: &cursor)
        guard Array(bytes[cursor..<(cursor + 4)]) == [0x70, 0x73, 0x73, 0x68] else {
            throw WidevineL3ClientError.invalidPSSH
        }
        cursor += 4
        let boxSize: Int
        if size32 == 1 {
            let size64 = try readUInt64(bytes, cursor: &cursor)
            guard size64 <= UInt64(Int.max) else {
                throw WidevineL3ClientError.invalidPSSH
            }
            boxSize = Int(size64)
        } else if size32 == 0 {
            boxSize = bytes.count
        } else {
            boxSize = Int(size32)
        }
        guard boxSize == bytes.count,
              cursor <= boxSize,
              boxSize - cursor >= 20 else {
            throw WidevineL3ClientError.invalidPSSH
        }

        let version = bytes[cursor]
        guard version == 0 || version == 1 else {
            throw WidevineL3ClientError.invalidPSSH
        }
        cursor += 4 // version and flags
        guard cursor <= boxSize, boxSize - cursor >= 16,
              Array(bytes[cursor..<(cursor + 16)]) == systemID else {
            throw WidevineL3ClientError.invalidPSSH
        }
        cursor += 16
        var boxKeyIDs: [Data] = []
        if version == 1 {
            let keyIDCount = try readUInt32(bytes, cursor: &cursor)
            let (keyIDBytes, overflow) = Int(keyIDCount).multipliedReportingOverflow(by: 16)
            guard !overflow,
                  cursor <= boxSize,
                  keyIDBytes <= boxSize - cursor else {
                throw WidevineL3ClientError.invalidPSSH
            }
            boxKeyIDs.reserveCapacity(Int(keyIDCount))
            for _ in 0..<Int(keyIDCount) {
                let keyID = Data(bytes[cursor..<(cursor + 16)])
                guard !boxKeyIDs.contains(keyID) else {
                    throw WidevineL3ClientError.invalidPSSH
                }
                boxKeyIDs.append(keyID)
                cursor += 16
            }
        }
        let dataLength = Int(try readUInt32(bytes, cursor: &cursor))
        guard cursor <= boxSize,
              dataLength == boxSize - cursor else {
            throw WidevineL3ClientError.invalidPSSH
        }
        if dataLength == 0 {
            guard !boxKeyIDs.isEmpty else {
                throw WidevineL3ClientError.invalidPSSH
            }
            var synthesized = WidevineProtobufWriter()
            for keyID in boxKeyIDs {
                synthesized.appendBytes(field: 2, value: keyID)
            }
            return synthesized.data
        }
        let payload = Data(bytes[cursor..<boxSize])
        if let payloadKeyIDs = try keyIDs(fromPayload: payload),
           !boxKeyIDs.isEmpty,
           payloadKeyIDs != Set(boxKeyIDs) {
            throw WidevineL3ClientError.invalidPSSH
        }
        return payload
    }

    /// Returns nil when the PSSH identifies content through content_id instead
    /// of an explicit KID list. In that case the license server, not the client,
    /// performs the content-id-to-KID mapping.
    static func keyIDs(fromPayload payload: Data) throws -> Set<Data>? {
        var reader: WidevineProtobufReader
        do {
            reader = try WidevineProtobufReader(payload)
        } catch {
            throw WidevineL3ClientError.invalidPSSH
        }
        var keyIDs = Set<Data>()
        do {
            while let field = try reader.next() {
                guard field.number == 2 else { continue }
                guard field.wireType == 2,
                      let keyID = field.bytes,
                      keyID.count == 16,
                      keyIDs.insert(keyID).inserted else {
                    throw WidevineL3ClientError.invalidPSSH
                }
            }
        } catch {
            throw WidevineL3ClientError.invalidPSSH
        }
        return keyIDs.isEmpty ? nil : keyIDs
    }

    private static func readUInt32(_ bytes: [UInt8], cursor: inout Int) throws -> UInt32 {
        guard cursor <= bytes.count, bytes.count - cursor >= 4 else {
            throw WidevineL3ClientError.invalidPSSH
        }
        let value = bytes[cursor..<(cursor + 4)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        cursor += 4
        return value
    }

    private static func readUInt64(_ bytes: [UInt8], cursor: inout Int) throws -> UInt64 {
        guard cursor <= bytes.count, bytes.count - cursor >= 8 else {
            throw WidevineL3ClientError.invalidPSSH
        }
        let value = bytes[cursor..<(cursor + 8)].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        cursor += 8
        return value
    }
}

enum WidevineDER {
    private static let rsaEncryptionOID: [UInt8] = [
        0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01
    ]

    static func pkcs1PrivateKey(fromPKCS8 data: Data) throws -> Data {
        var outer = DERReader(data)
        let sequence = try outer.read(expectedTag: 0x30)
        guard outer.isAtEnd else { throw WidevineL3ClientError.invalidPrivateKey }

        var fields = DERReader(sequence)
        let version = try fields.read(expectedTag: 0x02)
        guard version == Data([0x00]) || version == Data([0x01]) else {
            throw WidevineL3ClientError.invalidPrivateKey
        }
        let algorithm = try fields.read(expectedTag: 0x30)
        var algorithmFields = DERReader(algorithm)
        let oid = try algorithmFields.read(expectedTag: 0x06)
        guard [UInt8](oid) == rsaEncryptionOID else {
            throw WidevineL3ClientError.invalidPrivateKey
        }
        if !algorithmFields.isAtEnd {
            let null = try algorithmFields.read(expectedTag: 0x05)
            guard null.isEmpty else { throw WidevineL3ClientError.invalidPrivateKey }
        }
        guard algorithmFields.isAtEnd else {
            throw WidevineL3ClientError.invalidPrivateKey
        }
        let privateKey = try fields.read(expectedTag: 0x04)
        guard !privateKey.isEmpty else { throw WidevineL3ClientError.invalidPrivateKey }
        return privateKey
    }
}

private struct DERReader {
    private let bytes: [UInt8]
    private var cursor = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var isAtEnd: Bool { cursor == bytes.count }

    mutating func read(expectedTag: UInt8) throws -> Data {
        guard cursor < bytes.count, bytes[cursor] == expectedTag else {
            throw WidevineL3ClientError.invalidPrivateKey
        }
        cursor += 1
        let length = try readLength()
        guard cursor <= bytes.count, length <= bytes.count - cursor else {
            throw WidevineL3ClientError.invalidPrivateKey
        }
        let value = Data(bytes[cursor..<(cursor + length)])
        cursor += length
        return value
    }

    private mutating func readLength() throws -> Int {
        guard cursor < bytes.count else { throw WidevineL3ClientError.invalidPrivateKey }
        let first = bytes[cursor]
        cursor += 1
        if first & 0x80 == 0 { return Int(first) }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 4, cursor <= bytes.count, count <= bytes.count - cursor else {
            throw WidevineL3ClientError.invalidPrivateKey
        }
        guard bytes[cursor] != 0 else { throw WidevineL3ClientError.invalidPrivateKey }
        var length = 0
        for _ in 0..<count {
            let (shifted, overflow) = length.multipliedReportingOverflow(by: 256)
            guard !overflow else { throw WidevineL3ClientError.invalidPrivateKey }
            let (next, additionOverflow) = shifted.addingReportingOverflow(Int(bytes[cursor]))
            guard !additionOverflow else { throw WidevineL3ClientError.invalidPrivateKey }
            length = next
            cursor += 1
        }
        guard length >= 128 else { throw WidevineL3ClientError.invalidPrivateKey }
        return length
    }
}
