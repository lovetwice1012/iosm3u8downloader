import AVFoundation
import XCTest
@testable import HLSDownloader

final class TransportStreamRemuxerTests: XCTestCase {
    func testComposerRemuxesH264AACTransportStreamIntoPlayableMP4() async throws {
        let fixtureURL = try fixture(named: "sample-h264-aac.ts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureURL.path))

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hls-remux-test-\(UUID().uuidString).mp4"
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let sourceURL = URL(string: "https://example.com/video/segment.ts")!
        let source = MediaSegment(
            ordinal: 0,
            mediaSequence: 0,
            duration: 1.5,
            url: URLCandidates(primary: sourceURL, sameOriginQueryFallback: nil),
            byteRange: nil,
            encryption: nil,
            initializationMap: nil,
            hasDiscontinuity: false
        )
        let bytes = try Data(contentsOf: fixtureURL).count
        let segment = DownloadedSegment(
            source: source,
            fileURL: fixtureURL,
            container: .transportStream,
            byteCount: bytes,
            initializationDataLength: 0
        )

        try await MP4Composer().compose(
            main: [segment],
            externalAudio: nil,
            outputURL: outputURL
        )

        let values = try outputURL.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertGreaterThan(values.fileSize ?? 0, 0)

        let asset = AVURLAsset(url: outputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)

        let duration = try await asset.load(.duration)
        XCTAssertTrue(duration.isNumeric)
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 1.0)
    }

    func testComposerPreservesOffsetBetweenSeparateVideoAndAudioTransportStreams() async throws {
        let videoURL = try fixture(named: "sample-h264-video-offset.ts")
        let audioURL = try fixture(named: "sample-aac-audio-offset.ts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: videoURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hls-remux-offset-test-\(UUID().uuidString).mp4"
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try await MP4Composer().compose(
            main: [segment(fileURL: videoURL, duration: 3, name: "video")],
            externalAudio: [segment(fileURL: audioURL, duration: 2, name: "audio")],
            outputURL: outputURL
        )

        let asset = AVURLAsset(url: outputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let videoStart = CMTimeGetSeconds(try await firstPresentedTime(in: videoTrack))
        let audioStart = CMTimeGetSeconds(try await firstPresentedTime(in: audioTrack))

        XCTAssertLessThan(abs(videoStart), 0.2)
        XCTAssertGreaterThan(audioStart - videoStart, 0.7)
        XCTAssertLessThan(audioStart - videoStart, 1.2)
    }

    private func firstPresentedTime(in track: AVAssetTrack) async throws -> CMTime {
        // AVAssetTrack.timeRange includes an initial empty edit and therefore starts at zero.
        // The first non-empty segment is the point at which this track is actually presented.
        let segments = try await track.load(.segments)
        return try XCTUnwrap(segments.first(where: { !$0.isEmpty })).timeMapping.target.start
    }

    private func fixture(named name: String) throws -> URL {
        let filename = (name as NSString).deletingPathExtension
        let fileExtension = (name as NSString).pathExtension
        return try XCTUnwrap(
            Bundle(for: TransportStreamRemuxerTests.self).url(
                forResource: filename,
                withExtension: fileExtension
            )
        )
    }

    private func segment(
        fileURL: URL,
        duration: TimeInterval,
        name: String
    ) -> DownloadedSegment {
        let sourceURL = URL(string: "https://example.com/\(name).ts")!
        let source = MediaSegment(
            ordinal: 0,
            mediaSequence: 0,
            duration: duration,
            url: URLCandidates(primary: sourceURL, sameOriginQueryFallback: nil),
            byteRange: nil,
            encryption: nil,
            initializationMap: nil,
            hasDiscontinuity: false
        )
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        let byteCount = values?.fileSize ?? 0
        return DownloadedSegment(
            source: source,
            fileURL: fileURL,
            container: .transportStream,
            byteCount: byteCount,
            initializationDataLength: 0
        )
    }
}
