import Foundation
import Security

protocol WidevineCredentialStoring: Sendable {
    func save(_ wvdData: Data) throws
    func load() throws -> Data?
    func delete() throws
}

struct KeychainCredentialIdentifier: Hashable, Sendable {
    let service: String
    let account: String
}

protocol KeychainCredentialPersisting: Sendable {
    func save(_ data: Data, identifier: KeychainCredentialIdentifier) throws
    func load(identifier: KeychainCredentialIdentifier) throws -> Data?
    func delete(identifier: KeychainCredentialIdentifier) throws
}

enum KeychainCredentialError: LocalizedError, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case unexpectedStoredValue

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "資格情報を安全に保存できませんでした（Keychainエラー: \(status)）。"
        case .unexpectedStoredValue:
            return "Keychainに保存された資格情報を読み取れませんでした。"
        }
    }
}

struct SecurityKeychainCredentialPersistence: KeychainCredentialPersisting, Sendable {
    func save(_ data: Data, identifier: KeychainCredentialIdentifier) throws {
        let query = baseQuery(for: identifier)
        var newItem = query
        newItem[kSecValueData] = data
        newItem[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw KeychainCredentialError.unexpectedStatus(addStatus)
        }

        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw KeychainCredentialError.unexpectedStatus(updateStatus)
        }
    }

    func load(identifier: KeychainCredentialIdentifier) throws -> Data? {
        var query = baseQuery(for: identifier)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainCredentialError.unexpectedStatus(status)
        }
        guard let data = value as? Data else {
            throw KeychainCredentialError.unexpectedStoredValue
        }
        return data
    }

    func delete(identifier: KeychainCredentialIdentifier) throws {
        let status = SecItemDelete(baseQuery(for: identifier) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for identifier: KeychainCredentialIdentifier) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: identifier.service,
            kSecAttrAccount: identifier.account
        ]
    }
}

struct KeychainWidevineCredentialStore: WidevineCredentialStoring, Sendable {
    static let defaultIdentifier = KeychainCredentialIdentifier(
        service: "com.example.HLSDownloader.widevine",
        account: "l3-device-credential-v1"
    )

    private let identifier: KeychainCredentialIdentifier
    private let validator: WVDFileValidator
    private let persistence: any KeychainCredentialPersisting

    init(
        identifier: KeychainCredentialIdentifier = Self.defaultIdentifier,
        validator: WVDFileValidator = WVDFileValidator(),
        persistence: any KeychainCredentialPersisting = SecurityKeychainCredentialPersistence()
    ) {
        self.identifier = identifier
        self.validator = validator
        self.persistence = persistence
    }

    func save(_ wvdData: Data) throws {
        _ = try validator.validate(wvdData)
        try persistence.save(wvdData, identifier: identifier)
    }

    func load() throws -> Data? {
        guard let wvdData = try persistence.load(identifier: identifier) else {
            return nil
        }
        _ = try validator.validate(wvdData)
        return wvdData
    }

    func delete() throws {
        try persistence.delete(identifier: identifier)
    }
}
