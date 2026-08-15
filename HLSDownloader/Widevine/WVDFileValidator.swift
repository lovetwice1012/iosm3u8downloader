import Foundation

enum WVDFileSecurityLevel: UInt8, Sendable {
    case l3 = 3
}

struct WVDFileMetadata: Equatable, Sendable {
    let version: UInt8
    let securityLevel: WVDFileSecurityLevel
}

enum WVDFileValidationError: LocalizedError, Equatable, Sendable {
    case truncatedHeader
    case invalidMagic
    case unsupportedVersion
    case unsupportedSecurityLevel
    case truncatedPrivateKeyLength
    case emptyPrivateKey
    case truncatedPrivateKey
    case truncatedClientIdentificationLength
    case emptyClientIdentification
    case truncatedClientIdentification
    case trailingData

    var errorDescription: String? {
        switch self {
        case .truncatedHeader:
            return "WVDファイルのヘッダーが不完全です。"
        case .invalidMagic:
            return "WVDファイルの識別子が正しくありません。"
        case .unsupportedVersion:
            return "対応していないWVDファイルバージョンです。"
        case .unsupportedSecurityLevel:
            return "このWVD資格情報はWidevine L3ではありません。"
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
    private static let supportedVersion: UInt8 = 2
    private static let magic: [UInt8] = [0x57, 0x56, 0x44]

    func validate(_ data: Data) throws -> WVDFileMetadata {
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

        let rawSecurityLevel = byte(in: data, at: 5)
        guard let securityLevel = WVDFileSecurityLevel(rawValue: rawSecurityLevel),
              securityLevel == .l3 else {
            throw WVDFileValidationError.unsupportedSecurityLevel
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

        return WVDFileMetadata(version: version, securityLevel: securityLevel)
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
