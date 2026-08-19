import Foundation
import HLSFFmpegBridge
import XCTest
@testable import HLSDownloader

final class SampleAESFFmpegComposerTests: XCTestCase {
    func testAudioOnlyPrimaryUsesExternalAudioRenditionAsWAVPrimary() throws {
        let primary = URL(fileURLWithPath: "/tmp/primary.m3u8")
        let externalAudio = URL(fileURLWithPath: "/tmp/audio.m3u8")

        let selection = try SampleAESFFmpegComposer.executionSelection(
            primaryPlaylistURL: primary,
            externalAudioPlaylistURL: externalAudio,
            primaryTracks: [.audio],
            externalAudioTracks: [.audio]
        )

        XCTAssertEqual(selection.format, .wav)
        XCTAssertEqual(selection.primaryPlaylistURL, externalAudio)
        XCTAssertNil(selection.externalAudioPlaylistURL)
    }

    func testWAVValidatorRejectsEmptyDataChunk() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("empty.wav")
        let emptyPCM16WAV = Data([
            0x52, 0x49, 0x46, 0x46, 0x26, 0x00, 0x00, 0x00,
            0x57, 0x41, 0x56, 0x45,
            0x66, 0x6D, 0x74, 0x20, 0x10, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x01, 0x00,
            0x80, 0xBB, 0x00, 0x00,
            0x00, 0x77, 0x01, 0x00,
            0x02, 0x00, 0x10, 0x00,
            0x64, 0x61, 0x74, 0x61, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00
        ])
        try emptyPCM16WAV.write(to: output)

        XCTAssertThrowsError(
            try LocalFFmpegOutputValidation.validatePCM16WAV(at: output)
        )
    }

    func testWAVValidatorRejectsTruncatedDeclaredDataChunk() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "truncated-wav-\(UUID().uuidString).wav"
        )
        defer { try? FileManager.default.removeItem(at: output) }
        var truncated = Data("RIFF".utf8)
        truncated.append(contentsOf: [0x64, 0, 0, 0])
        truncated.append(Data("WAVEfmt ".utf8))
        truncated.append(contentsOf: [16, 0, 0, 0])
        truncated.append(contentsOf: [1, 0, 1, 0])
        truncated.append(contentsOf: [0x40, 0x1F, 0, 0])
        truncated.append(contentsOf: [0x80, 0x3E, 0, 0])
        truncated.append(contentsOf: [2, 0, 16, 0])
        truncated.append(Data("data".utf8))
        truncated.append(contentsOf: [64, 0, 0, 0, 0])
        try truncated.write(to: output)

        XCTAssertFalse(WidevineMediaOutputValidator.isValid(output, format: .wav))
        XCTAssertThrowsError(
            try LocalFFmpegOutputValidation.validatePCM16WAV(at: output)
        )
    }

    func testFFmpegOutputLimitReservesDiskAndAppliesAbsoluteCap() {
        let reserve = LocalFFmpegOutputLimit.reservedFreeBytes
        let minimum = LocalFFmpegOutputLimit.minimumUsableBytes
        let absolute = LocalFFmpegOutputLimit.absoluteMaximumBytes

        XCTAssertNil(LocalFFmpegOutputLimit.maximumBytes(availableBytes: reserve))
        XCTAssertNil(
            LocalFFmpegOutputLimit.maximumBytes(
                availableBytes: reserve + minimum - 1
            )
        )
        XCTAssertEqual(
            LocalFFmpegOutputLimit.maximumBytes(availableBytes: reserve + minimum),
            minimum
        )
        XCTAssertEqual(
            LocalFFmpegOutputLimit.maximumBytes(availableBytes: reserve + absolute + 1_024),
            absolute
        )
    }

    func testFFmpegOutputLimitRejectsLimitHit() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("bounded-output.bin")
        try Data(repeating: 0x5a, count: 32).write(to: output)

        XCTAssertNoThrow(
            try LocalFFmpegOutputLimit.validateCompletedOutput(at: output, maximumBytes: 33)
        )
        XCTAssertThrowsError(
            try LocalFFmpegOutputLimit.validateCompletedOutput(at: output, maximumBytes: 32)
        )
    }

    func testFFmpegInputBudgetCountsUniqueRegularFilesAndRejectsExactLimit() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.bin")
        let second = directory.appendingPathComponent("second.bin")
        try Data(repeating: 0x11, count: 17).write(to: first)
        try Data(repeating: 0x22, count: 19).write(to: second)

        XCTAssertEqual(
            try LocalFFmpegOutputLimit.validateInputFiles(
                [first, first, second],
                maximumBytes: 37
            ),
            36
        )
        XCTAssertThrowsError(
            try LocalFFmpegOutputLimit.validateInputFiles(
                [first, second],
                maximumBytes: 36
            )
        )
    }

    func testBridgeRejectsOutputThatHitsSoftFFmpegFileSizeLimit() throws {
        let input = try fixture(named: "sample-aac-audio-offset.ts")
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("capped.wav")
        let session = input.path.withCString { inputPath in
            output.path.withCString { outputPath in
                hls_ffmpeg_audio_wav_session_create(inputPath, nil, outputPath, 1_024)
            }
        }
        let unwrapped = try XCTUnwrap(session)
        defer { hls_ffmpeg_remux_session_destroy(unwrapped) }
        var diagnostic = [CChar](repeating: 0, count: 1_024)
        let result = diagnostic.withUnsafeMutableBufferPointer { buffer in
            hls_ffmpeg_remux_session_execute(
                unwrapped,
                buffer.baseAddress,
                buffer.count
            )
        }

        XCTAssertNotEqual(result, 0)
    }

    func testActualTrackProbeAndAudioOnlyPCMOutput() async throws {
        let input = try fixture(named: "sample-aac-audio-offset.ts")
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("audio-output.part")

        let tracks = try await LocalMediaTrackProbe().probe(
            inputURL: input,
            input: .mediaFile()
        )
        XCTAssertTrue(tracks.contains(.audio))
        XCTAssertFalse(tracks.contains(.video))

        try await FFmpegAudioWAVComposer().compose(
            inputURL: input,
            outputURL: output
        )
        let prefix = try Data(contentsOf: output).prefix(12)
        XCTAssertTrue(
            prefix.starts(with: Data("RIFF".utf8))
                || prefix.starts(with: Data("RF64".utf8))
        )
        XCTAssertEqual(String(decoding: prefix.dropFirst(8), as: UTF8.self), "WAVE")
    }

    func testSampleAESComposerRejectsKeyThatWasNotRegisteredForDiagnostics() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try fixture(named: "sample-h264-aac.ts")
        let segment = directory.appendingPathComponent("segment-000.ts")
        try FileManager.default.copyItem(at: input, to: segment)
        let actualKey = Data(repeating: 0x11, count: 16)
        try actualKey.write(to: directory.appendingPathComponent("content.key"))
        let playlist = directory.appendingPathComponent("local.m3u8")
        try Data(
            """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-KEY:METHOD=SAMPLE-AES,URI="content.key",KEYFORMAT="identity"
            #EXTINF:1,
            segment-000.ts
            #EXT-X-ENDLIST

            """.utf8
        ).write(to: playlist)

        await XCTAssertThrowsErrorAsync {
            _ = try await SampleAESFFmpegComposer().compose(
                primaryPlaylistURL: playlist,
                diagnosticKeys: [Data(repeating: 0x22, count: 16)],
                outputURL: directory.appendingPathComponent("output.part")
            )
        }
    }

    func testSampleAESComposerRejectsPlaylistTraversalBeforeFFmpeg() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("job", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = Data(repeating: 0x33, count: 16)
        try key.write(to: parent.appendingPathComponent("content.key"))
        let playlist = directory.appendingPathComponent("local.m3u8")
        try Data(
            """
            #EXTM3U
            #EXT-X-KEY:METHOD=SAMPLE-AES,URI="../content.key",KEYFORMAT="identity"
            #EXTINF:1,
            ../segment.ts
            #EXT-X-ENDLIST

            """.utf8
        ).write(to: playlist)

        await XCTAssertThrowsErrorAsync {
            _ = try await SampleAESFFmpegComposer().compose(
                primaryPlaylistURL: playlist,
                diagnosticKeys: [key],
                outputURL: directory.appendingPathComponent("output.part")
            )
        }
    }

    func testSampleAESWrongKeyCannotPublishPartialWAV() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let protectedAudio = directory.appendingPathComponent("protected.aac")
        try sampleAESEncryptedAACFixtureData().write(to: protectedAudio, options: .atomic)
        let keyFile = directory.appendingPathComponent("content.key")
        let playlist = directory.appendingPathComponent("local.m3u8")
        try Data(
            """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:1
            #EXT-X-MEDIA-SEQUENCE:0
            #EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT="identity",URI="content.key",IV=0x00000000000000000000000000000000
            #EXTINF:0.35,
            protected.aac
            #EXT-X-ENDLIST

            """.utf8
        ).write(to: playlist, options: .atomic)

        let correctKey = Data((0x30...0x3f).map { UInt8($0) })
        try correctKey.write(to: keyFile, options: .atomic)
        let validOutput = directory.appendingPathComponent("valid.wav")
        let validFormat = try await SampleAESFFmpegComposer().compose(
            primaryPlaylistURL: playlist,
            diagnosticKeys: [correctKey],
            outputURL: validOutput
        )
        XCTAssertEqual(validFormat, .wav)
        try LocalFFmpegOutputValidation.validatePCM16WAV(at: validOutput)

        let wrongKey = Data((0x50...0x5f).map { UInt8($0) })
        try wrongKey.write(to: keyFile, options: .atomic)
        let wrongKeyTracks = try await LocalMediaTrackProbe().probe(
            inputURL: playlist,
            input: .sampleAESPlaylist(diagnosticKeys: [wrongKey])
        )
        XCTAssertTrue(wrongKeyTracks.contains(.audio))

        let rejectedOutput = directory.appendingPathComponent("wrong-key.wav")
        do {
            _ = try await SampleAESFFmpegComposer().compose(
                primaryPlaylistURL: playlist,
                diagnosticKeys: [wrongKey],
                outputURL: rejectedOutput
            )
            XCTFail("Wrong SAMPLE-AES audio keys must fail strict decoding")
        } catch {
            let description = error.localizedDescription.lowercased()
            XCTAssertFalse(description.contains(wrongKey.map { String(format: "%02x", $0) }.joined()))
            XCTAssertFalse(description.contains(wrongKey.base64EncodedString().lowercased()))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedOutput.path))
    }

    private func fixture(named name: String) throws -> URL {
        let filename = (name as NSString).deletingPathExtension
        let fileExtension = (name as NSString).pathExtension
        return try XCTUnwrap(
            Bundle(for: SampleAESFFmpegComposerTests.self).url(
                forResource: filename,
                withExtension: fileExtension
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SampleAESFFmpegComposerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private func sampleAESEncryptedAACFixtureData() -> Data {
    Data(
        base64Encoded: "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"
    )!
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
