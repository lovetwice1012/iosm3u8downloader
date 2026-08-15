import Foundation
import XCTest
@testable import HLSDownloader

final class WidevineFFmpegMediaComposerTests: XCTestCase {
    func testRejectsMissingVideoAndInvalidKeyBeforeStartingFFmpeg() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "widevine-ffmpeg-validation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = directory.appendingPathComponent("output.mp4")
        let composer = FFmpegWidevineMediaComposer()
        do {
            try await composer.decryptAndMux(video: nil, audio: nil, outputURL: output)
            XCTFail("A video track is required")
        } catch {
            XCTAssertEqual(error as? WidevineDASHProviderError, .invalidMediaOutput)
        }

        let encrypted = directory.appendingPathComponent("encrypted.mp4")
        try Data("not-media".utf8).write(to: encrypted)
        let invalidInput = WidevineEncryptedTrackInput(
            encryptedFileURL: encrypted,
            keyData: Data(repeating: 0xAB, count: 15),
            scheme: .cenc
        )
        do {
            try await composer.decryptAndMux(
                video: invalidInput,
                audio: nil,
                outputURL: output
            )
            XCTFail("A Widevine content key must contain exactly 16 bytes")
        } catch {
            XCTAssertEqual(error as? WidevineDASHProviderError, .invalidMediaOutput)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testFFmpegFailureDoesNotExposeTheContentKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "widevine-ffmpeg-redaction-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let encrypted = directory.appendingPathComponent("invalid.mp4")
        try Data("not-an-encrypted-mp4".utf8).write(to: encrypted)
        let output = directory.appendingPathComponent("output.mp4")
        let key = Data(repeating: 0xAB, count: 16)
        let input = WidevineEncryptedTrackInput(
            encryptedFileURL: encrypted,
            keyData: key,
            scheme: .cbcs
        )

        do {
            try await FFmpegWidevineMediaComposer().decryptAndMux(
                video: input,
                audio: nil,
                outputURL: output
            )
            XCTFail("Invalid media must not be accepted")
        } catch {
            let description = error.localizedDescription.lowercased()
            XCTAssertFalse(description.contains(String(repeating: "ab", count: 16)))
            XCTAssertFalse(description.contains(key.base64EncodedString().lowercased()))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
