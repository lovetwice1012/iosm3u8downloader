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
