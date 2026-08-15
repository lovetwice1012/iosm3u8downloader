import Foundation
import XCTest
@testable import HLSDownloader

final class WidevineCredentialStoreTests: XCTestCase {
    func testSaveValidatesThenPersistsWVDData() throws {
        let persistence = FakeKeychainCredentialPersistence()
        let identifier = KeychainCredentialIdentifier(
            service: "test.widevine",
            account: "credential"
        )
        let store = KeychainWidevineCredentialStore(
            identifier: identifier,
            persistence: persistence
        )
        let wvdData = makeWVD()

        try store.save(wvdData)

        XCTAssertEqual(persistence.savedData, wvdData)
        XCTAssertEqual(persistence.savedIdentifier, identifier)
        XCTAssertEqual(persistence.saveCallCount, 1)
    }

    func testSaveRejectsMalformedDataBeforePersistence() {
        let persistence = FakeKeychainCredentialPersistence()
        let store = KeychainWidevineCredentialStore(persistence: persistence)

        XCTAssertThrowsError(try store.save(Data([0x01, 0x02]))) { error in
            XCTAssertEqual(error as? WVDFileValidationError, .truncatedHeader)
        }
        XCTAssertEqual(persistence.saveCallCount, 0)
    }

    func testLoadReturnsNilWhenCredentialDoesNotExist() throws {
        let persistence = FakeKeychainCredentialPersistence()
        let store = KeychainWidevineCredentialStore(persistence: persistence)

        XCTAssertNil(try store.load())
    }

    func testLoadReturnsValidatedStoredCredential() throws {
        let wvdData = makeWVD()
        let persistence = FakeKeychainCredentialPersistence(initialData: wvdData)
        let store = KeychainWidevineCredentialStore(persistence: persistence)

        XCTAssertEqual(try store.load(), wvdData)
    }

    func testLoadRejectsCorruptedStoredCredential() {
        let persistence = FakeKeychainCredentialPersistence(initialData: Data([0x01, 0x02]))
        let store = KeychainWidevineCredentialStore(persistence: persistence)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? WVDFileValidationError, .truncatedHeader)
        }
    }

    func testDeleteUsesTheConfiguredIdentifier() throws {
        let persistence = FakeKeychainCredentialPersistence(initialData: makeWVD())
        let identifier = KeychainCredentialIdentifier(
            service: "test.widevine",
            account: "credential"
        )
        let store = KeychainWidevineCredentialStore(
            identifier: identifier,
            persistence: persistence
        )

        try store.delete()

        XCTAssertEqual(persistence.deletedIdentifier, identifier)
        XCTAssertNil(persistence.savedData)
    }

    private func makeWVD() -> Data {
        Data([
            0x57, 0x56, 0x44, 0x02, 0x01, 0x03, 0x00,
            0x00, 0x02, 0xA1, 0xA2,
            0x00, 0x02, 0xB1, 0xB2
        ])
    }
}

private final class FakeKeychainCredentialPersistence: KeychainCredentialPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data?
    private var storedIdentifier: KeychainCredentialIdentifier?
    private var removedIdentifier: KeychainCredentialIdentifier?
    private var saveCalls = 0

    init(initialData: Data? = nil) {
        storedData = initialData
    }

    var savedData: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    var savedIdentifier: KeychainCredentialIdentifier? {
        lock.lock()
        defer { lock.unlock() }
        return storedIdentifier
    }

    var deletedIdentifier: KeychainCredentialIdentifier? {
        lock.lock()
        defer { lock.unlock() }
        return removedIdentifier
    }

    var saveCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saveCalls
    }

    func save(_ data: Data, identifier: KeychainCredentialIdentifier) throws {
        lock.lock()
        storedData = data
        storedIdentifier = identifier
        saveCalls += 1
        lock.unlock()
    }

    func load(identifier: KeychainCredentialIdentifier) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    func delete(identifier: KeychainCredentialIdentifier) throws {
        lock.lock()
        storedData = nil
        removedIdentifier = identifier
        lock.unlock()
    }
}
