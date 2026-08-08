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
        let sampleTimes = try firstSamplePresentationTimes(
            in: asset,
            videoTrack: videoTrack,
            audioTrack: audioTrack
        )
        let videoStart = CMTimeGetSeconds(sampleTimes.video)
        let audioStart = CMTimeGetSeconds(sampleTimes.audio)

        XCTAssertLessThan(abs(videoStart), 0.2, "video start: \(videoStart)")
        XCTAssertGreaterThan(
            audioStart - videoStart,
            0.7,
            "video start: \(videoStart), audio start: \(audioStart)"
        )
        XCTAssertLessThan(
            audioStart - videoStart,
            1.2,
            "video start: \(videoStart), audio start: \(audioStart)"
        )
    }

    private enum SampleReadError: Error {
        case cannotAddOutput
        case cannotStartReading
        case noSample
        case invalidPresentationTime
    }

    private func firstSamplePresentationTimes(
        in asset: AVAsset,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack
    ) throws -> (video: CMTime, audio: CMTime) {
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        audioOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput), reader.canAdd(audioOutput) else {
            throw SampleReadError.cannotAddOutput
        }
        reader.add(videoOutput)
        reader.add(audioOutput)
        guard reader.startReading() else {
            if let error = reader.error { throw error }
            throw SampleReadError.cannotStartReading
        }
        defer { reader.cancelReading() }
        guard let videoSample = videoOutput.copyNextSampleBuffer(),
              let audioSample = audioOutput.copyNextSampleBuffer() else {
            if let error = reader.error { throw error }
            throw SampleReadError.noSample
        }
        let videoTime = CMSampleBufferGetPresentationTimeStamp(videoSample)
        let audioTime = CMSampleBufferGetPresentationTimeStamp(audioSample)
        guard videoTime.isValid, videoTime.isNumeric,
              audioTime.isValid, audioTime.isNumeric else {
            throw SampleReadError.invalidPresentationTime
        }
        return (videoTime, audioTime)
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
