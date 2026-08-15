import XCTest
@testable import HLSDownloader

final class WVDFileValidatorTests: XCTestCase {
    private let validator = WVDFileValidator()

    func testAcceptsStructurallyValidVersion2L3File() throws {
        let metadata = try validator.validate(makeWVD())

        XCTAssertEqual(metadata.version, 2)
        XCTAssertEqual(metadata.deviceType, .chrome)
        XCTAssertEqual(metadata.securityLevel, .l3)
    }

    func testRejectsEveryTruncatedHeader() {
        let header: [UInt8] = [0x57, 0x56, 0x44, 0x02, 0x01, 0x03, 0x00]

        for length in 0..<header.count {
            XCTAssertThrowsError(try validator.validate(Data(header.prefix(length)))) { error in
                XCTAssertEqual(error as? WVDFileValidationError, .truncatedHeader)
            }
        }
    }

    func testRejectsOversizedCredentialBeforeParsing() {
        XCTAssertThrowsError(
            try validator.validate(Data(repeating: 0, count: 256 * 1_024 + 1))
        ) { error in
            XCTAssertEqual(error as? WVDFileValidationError, .fileTooLarge)
        }
    }

    func testRejectsInvalidMagicWithoutIncludingBytesInError() {
        var data = makeWVD()
        data[data.startIndex] = 0x00

        XCTAssertThrowsError(try validator.validate(data)) { error in
            XCTAssertEqual(error as? WVDFileValidationError, .invalidMagic)
            XCTAssertFalse(error.localizedDescription.contains("00"))
        }
    }

    func testRejectsUnsupportedVersionAndSecurityLevel() {
        var unsupportedVersion = makeWVD()
        unsupportedVersion[unsupportedVersion.startIndex + 3] = 1
        XCTAssertThrowsError(try validator.validate(unsupportedVersion)) { error in
            XCTAssertEqual(error as? WVDFileValidationError, .unsupportedVersion)
        }

        var nonL3 = makeWVD()
        nonL3[nonL3.startIndex + 5] = 1
        XCTAssertThrowsError(try validator.validate(nonL3)) { error in
            XCTAssertEqual(error as? WVDFileValidationError, .unsupportedSecurityLevel)
        }

        var unsupportedDevice = makeWVD()
        unsupportedDevice[unsupportedDevice.startIndex + 4] = 0xFF
        XCTAssertThrowsError(try validator.validate(unsupportedDevice)) { error in
            XCTAssertEqual(error as? WVDFileValidationError, .unsupportedDeviceType)
        }

        var unsupportedFlags = makeWVD()
        unsupportedFlags[unsupportedFlags.startIndex + 6] = 0x01
        XCTAssertThrowsError(try validator.validate(unsupportedFlags)) { error in
            XCTAssertEqual(error as? WVDFileValidationError, .unsupportedFlags)
        }
    }

    func testRejectsTruncatedOrEmptyPrivateKey() {
        let header = Data([0x57, 0x56, 0x44, 0x02, 0x01, 0x03, 0x00])

        XCTAssertThrowsError(try validator.validate(header)) { error in
            XCTAssertEqual(error as? WVDFileValidationError, .truncatedPrivateKeyLength)
        }
        XCTAssertThrowsError(try validator.validate(header + Data([0x00]))) { error in
            XCTAssertEqual(error as? WVDFileValidationError, .truncatedPrivateKeyLength)
        }
        XCTAssertThrowsError(try validator.validate(header + Data([0x00, 0x00]))) { error in
            XCTAssertEqual(error as? WVDFileValidationError, .emptyPrivateKey)
        }
        XCTAssertThrowsError(
            try validator.validate(header + Data([0x00, 0x02, 0xA5]))
        ) { error in
            XCTAssertEqual(error as? WVDFileValidationError, .truncatedPrivateKey)
        }
    }

    func testRejectsTruncatedOrEmptyClientIdentification() {
        let throughPrivateKey = Data([
            0x57, 0x56, 0x44, 0x02, 0x01, 0x03, 0x00,
            0x00, 0x01, 0xA5
        ])

        XCTAssertThrowsError(try validator.validate(throughPrivateKey)) { error in
            XCTAssertEqual(error as? WVDFileValidationError, .truncatedClientIdentificationLength)
        }
        XCTAssertThrowsError(
            try validator.validate(throughPrivateKey + Data([0x00]))
        ) { error in
            XCTAssertEqual(error as? WVDFileValidationError, .truncatedClientIdentificationLength)
        }
        XCTAssertThrowsError(
            try validator.validate(throughPrivateKey + Data([0x00, 0x00]))
        ) { error in
            XCTAssertEqual(error as? WVDFileValidationError, .emptyClientIdentification)
        }
        XCTAssertThrowsError(
            try validator.validate(throughPrivateKey + Data([0x00, 0x02, 0xB6]))
        ) { error in
            XCTAssertEqual(error as? WVDFileValidationError, .truncatedClientIdentification)
        }
    }

    func testRejectsTrailingData() {
        var data = makeWVD()
        data.append(0xFF)

        XCTAssertThrowsError(try validator.validate(data)) { error in
            XCTAssertEqual(error as? WVDFileValidationError, .trailingData)
        }
    }

    func testValidationErrorsNeverIncludeCredentialContents() {
        let privateMarker = Array("PRIVATE-MARKER".utf8)
        let clientMarker = Array("CLIENT-MARKER".utf8)
        var data = makeWVD(privateKey: privateMarker, clientIdentification: clientMarker)
        data.append(0x00)

        XCTAssertThrowsError(try validator.validate(data)) { error in
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE-MARKER"))
            XCTAssertFalse(error.localizedDescription.contains("CLIENT-MARKER"))
        }
    }

    private func makeWVD(
        privateKey: [UInt8] = [0xA1, 0xA2, 0xA3],
        clientIdentification: [UInt8] = [0xB1, 0xB2]
    ) -> Data {
        var result = Data([0x57, 0x56, 0x44, 0x02, 0x01, 0x03, 0x00])
        appendLength(privateKey.count, to: &result)
        result.append(contentsOf: privateKey)
        appendLength(clientIdentification.count, to: &result)
        result.append(contentsOf: clientIdentification)
        return result
    }

    private func appendLength(_ length: Int, to data: inout Data) {
        precondition(length <= Int(UInt16.max))
        let value = UInt16(length)
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }
}
