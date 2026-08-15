import Foundation

enum WVDFileSecurityLevel: UInt8, Sendable {
    case l3 = 3
}

enum WVDFileDeviceType: UInt8, Sendable {
    case chrome = 1
    case android = 2
}

struct WVDFileMetadata: Equatable, Sendable {
    let version: UInt8
    let deviceType: WVDFileDeviceType
    let securityLevel: WVDFileSecurityLevel
}

enum WVDFileValidationError: LocalizedError, Equatable, Sendable {
    case fileTooLarge
    case truncatedHeader
    case invalidMagic
    case unsupportedVersion
    case unsupportedDeviceType
    case unsupportedSecurityLevel
    case unsupportedFlags
    case truncatedPrivateKeyLength
    case emptyPrivateKey
    case truncatedPrivateKey
    case truncatedClientIdentificationLength
    case emptyClientIdentification
    case truncatedClientIdentification
    case trailingData

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "WVDファイルが許容サイズを超えています。"
        case .truncatedHeader:
            return "WVDファイルのヘッダーが不完全です。"
        case .invalidMagic:
            return "WVDファイルの識別子が正しくありません。"
        case .unsupportedVersion:
            return "対応していないWVDファイルバージョンです。"
        case .unsupportedDeviceType:
            return "対応していないWVDデバイス種別です。"
        case .unsupportedSecurityLevel:
            return "このWVD資格情報はWidevine L3ではありません。"
        case .unsupportedFlags:
            return "対応していないWVDフラグが設定されています。"
        case .truncatedPrivateKeyLength,
             .truncatedPrivateKey,
             .truncatedClientIdentificationLength,
             .truncatedClientIdentification,
             .trailingData:
            return "WVDファイルの構造が正しくありません。"
        case .emptyPrivateKey:
            return "WVDファイルにデバイス秘密鍵が含まれていません。"
        case .emptyClientIdentification:
            return "WVDファイルにクライアント識別情報が含まれていません。"
        }
    }
}

struct WVDFileValidator: Sendable {
    private static let headerLength = 7
    private static let maximumFileBytes = 256 * 1_024
    private static let supportedVersion: UInt8 = 2
    private static let magic: [UInt8] = [0x57, 0x56, 0x44]

    func validate(_ data: Data) throws -> WVDFileMetadata {
        guard data.count <= Self.maximumFileBytes else {
            throw WVDFileValidationError.fileTooLarge
        }
        guard data.count >= Self.headerLength else {
            throw WVDFileValidationError.truncatedHeader
        }

        guard byte(in: data, at: 0) == Self.magic[0],
              byte(in: data, at: 1) == Self.magic[1],
              byte(in: data, at: 2) == Self.magic[2] else {
            throw WVDFileValidationError.invalidMagic
        }

        let version = byte(in: data, at: 3)
        guard version == Self.supportedVersion else {
            throw WVDFileValidationError.unsupportedVersion
        }

        guard let deviceType = WVDFileDeviceType(rawValue: byte(in: data, at: 4)) else {
            throw WVDFileValidationError.unsupportedDeviceType
        }

        let rawSecurityLevel = byte(in: data, at: 5)
        guard let securityLevel = WVDFileSecurityLevel(rawValue: rawSecurityLevel),
              securityLevel == .l3 else {
            throw WVDFileValidationError.unsupportedSecurityLevel
        }

        guard byte(in: data, at: 6) == 0 else {
            throw WVDFileValidationError.unsupportedFlags
        }

        var cursor = Self.headerLength
        let privateKeyLength = try readLength(
            from: data,
            cursor: &cursor,
            truncatedError: .truncatedPrivateKeyLength
        )
        guard privateKeyLength > 0 else {
            throw WVDFileValidationError.emptyPrivateKey
        }
        try skip(
            privateKeyLength,
            in: data,
            cursor: &cursor,
            truncatedError: .truncatedPrivateKey
        )

        let clientIdentificationLength = try readLength(
            from: data,
            cursor: &cursor,
            truncatedError: .truncatedClientIdentificationLength
        )
        guard clientIdentificationLength > 0 else {
            throw WVDFileValidationError.emptyClientIdentification
        }
        try skip(
            clientIdentificationLength,
            in: data,
            cursor: &cursor,
            truncatedError: .truncatedClientIdentification
        )

        guard cursor == data.count else {
            throw WVDFileValidationError.trailingData
        }

        return WVDFileMetadata(
            version: version,
            deviceType: deviceType,
            securityLevel: securityLevel
        )
    }

    private func readLength(
        from data: Data,
        cursor: inout Int,
        truncatedError: WVDFileValidationError
    ) throws -> Int {
        guard cursor <= data.count, data.count - cursor >= 2 else {
            throw truncatedError
        }

        let high = UInt16(byte(in: data, at: cursor))
        let low = UInt16(byte(in: data, at: cursor + 1))
        cursor += 2
        return Int((high << 8) | low)
    }

    private func skip(
        _ length: Int,
        in data: Data,
        cursor: inout Int,
        truncatedError: WVDFileValidationError
    ) throws {
        guard length >= 0,
              cursor <= data.count,
              length <= data.count - cursor else {
            throw truncatedError
        }
        cursor += length
    }

    private func byte(in data: Data, at offset: Int) -> UInt8 {
        data[data.index(data.startIndex, offsetBy: offset)]
    }
}
