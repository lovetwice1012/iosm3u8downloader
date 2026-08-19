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

    func testAudioOnlyCENCRejectsWrongKeyAfterMetadataProbeSucceeds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "widevine-cenc-audio-strict-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let encrypted = directory.appendingPathComponent("encrypted-audio.m4a")
        try cencAudioFixtureData().write(to: encrypted, options: .atomic)
        let correctKey = Data([
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
        ])
        let wrongKey = Data([
            0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88,
            0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00
        ])

        // CENC metadata remains probeable with the wrong key. The compose
        // operation must therefore fail on actual AAC sample decoding.
        let wrongKeyTracks = try await LocalMediaTrackProbe().probe(
            inputURL: encrypted,
            input: .mediaFile(decryptionKey: wrongKey)
        )
        XCTAssertTrue(wrongKeyTracks.contains(.audio))
        XCTAssertFalse(wrongKeyTracks.contains(.video))

        let validOutput = directory.appendingPathComponent("valid.wav")
        try await FFmpegWidevineMediaComposer().decryptAndMux(
            video: nil,
            audio: WidevineEncryptedTrackInput(
                encryptedFileURL: encrypted,
                keyData: correctKey,
                scheme: .cenc
            ),
            outputURL: validOutput
        )
        try LocalFFmpegOutputValidation.validatePCM16WAV(at: validOutput)

        let rejectedOutput = directory.appendingPathComponent("wrong-key.wav")
        do {
            try await FFmpegWidevineMediaComposer().decryptAndMux(
                video: nil,
                audio: WidevineEncryptedTrackInput(
                    encryptedFileURL: encrypted,
                    keyData: wrongKey,
                    scheme: .cenc
                ),
                outputURL: rejectedOutput
            )
            XCTFail("A wrong CENC audio key must fail strict sample decoding")
        } catch {
            let description = error.localizedDescription.lowercased()
            XCTAssertFalse(description.contains(wrongKey.map { String(format: "%02x", $0) }.joined()))
            XCTAssertFalse(description.contains(wrongKey.base64EncodedString().lowercased()))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedOutput.path))
    }
}

private func cencAudioFixtureData() -> Data {
    Data(
        base64Encoded: "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"
    )!
}
