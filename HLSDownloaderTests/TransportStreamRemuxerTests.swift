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
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        XCTAssertGreaterThan(duration, 2.5)
        XCTAssertLessThan(duration, 3.5)

        let editStarts = try initialEmptyEditDurations(at: outputURL)
        let videoStart = try XCTUnwrap(editStarts["vide"])
        let audioStart = try XCTUnwrap(editStarts["soun"])

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

    func testAudioOnlyComposerRejectsUnconsolidatableSegmentsInsteadOfTruncating() async throws {
        let fixtureURL = try fixture(named: "sample-h264-aac.ts")
        let sourceURL = URL(string: "https://example.com/audio")!
        func makeSegment(ordinal: Int, container: MediaContainer) -> DownloadedSegment {
            DownloadedSegment(
                source: MediaSegment(
                    ordinal: ordinal,
                    mediaSequence: UInt64(ordinal),
                    duration: 1,
                    url: URLCandidates(primary: sourceURL, sameOriginQueryFallback: nil),
                    byteRange: nil,
                    encryption: nil,
                    initializationMap: nil,
                    hasDiscontinuity: false
                ),
                fileURL: fixtureURL,
                container: container,
                byteCount: 1,
                initializationDataLength: 0
            )
        }
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audio-truncation-guard-\(UUID().uuidString).wav"
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        do {
            try await MP4Composer().compose(
                main: [
                    makeSegment(ordinal: 0, container: .aac),
                    makeSegment(ordinal: 1, container: .mp3)
                ],
                externalAudio: nil,
                format: .wav,
                outputURL: outputURL
            )
            XCTFail("Expected an explicit non-truncating failure")
        } catch let error as HLSError {
            guard case .invalidPlaylist(let detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("without truncation"))
        }
    }

    func testOutputFormatUsesActualTracksForVideoAndAudioOnlyMedia() async throws {
        let videoURL = try fixture(named: "sample-h264-aac.ts")
        let audioURL = try fixture(named: "sample-aac-audio-offset.ts")
        let composer = MP4Composer()

        let videoFormat = try await composer.outputFormat(
            main: [segment(fileURL: videoURL, duration: 1.5, name: "video")],
            externalAudio: nil
        )
        let audioFormat = try await composer.outputFormat(
            main: [segment(fileURL: audioURL, duration: 2, name: "audio")],
            externalAudio: nil
        )
        XCTAssertEqual(videoFormat, .mp4)
        XCTAssertEqual(audioFormat, .wav)
    }

    func testAES128DecryptedAudioUsesActualTracksAndChoosesWAV() async throws {
        let audioURL = try fixture(named: "sample-aac-audio-offset.ts")
        let keyURL = URL(string: "https://example.com/key")!
        let source = MediaSegment(
            ordinal: 0,
            mediaSequence: 0,
            duration: 2,
            url: URLCandidates(
                primary: URL(string: "https://example.com/audio.ts")!,
                sameOriginQueryFallback: nil
            ),
            byteRange: nil,
            encryption: EncryptionDescriptor(
                method: .aes128,
                keyURL: URLCandidates(primary: keyURL, sameOriginQueryFallback: nil),
                explicitIV: Data(repeating: 0, count: 16)
            ),
            initializationMap: nil,
            hasDiscontinuity: false
        )
        let byteCount = try Data(contentsOf: audioURL).count
        let decrypted = DownloadedSegment(
            source: source,
            fileURL: audioURL,
            container: .transportStream,
            byteCount: byteCount,
            initializationDataLength: 0
        )

        let outputFormat = try await MP4Composer().outputFormat(
            main: [decrypted],
            externalAudio: nil
        )
        XCTAssertEqual(outputFormat, .wav)
    }

    private struct MP4Box {
        let type: String
        let payload: Range<Int>
    }

    private enum MP4InspectionError: Error {
        case malformed(String)
    }

    private func initialEmptyEditDurations(at url: URL) throws -> [String: TimeInterval] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let topLevel = try mp4Boxes(in: data, range: 0..<data.count)
        guard let movie = topLevel.first(where: { $0.type == "moov" }) else {
            throw MP4InspectionError.malformed("moov box not found")
        }
        let movieChildren = try mp4Boxes(in: data, range: movie.payload)
        guard let header = movieChildren.first(where: { $0.type == "mvhd" }) else {
            throw MP4InspectionError.malformed("mvhd box not found")
        }
        let timescale = try movieTimescale(in: data, header: header)
        var result: [String: TimeInterval] = [:]

        for track in movieChildren where track.type == "trak" {
            let trackChildren = try mp4Boxes(in: data, range: track.payload)
            guard let media = trackChildren.first(where: { $0.type == "mdia" }) else { continue }
            let mediaChildren = try mp4Boxes(in: data, range: media.payload)
            guard let handlerBox = mediaChildren.first(where: { $0.type == "hdlr" }) else { continue }
            guard handlerBox.payload.count >= 12 else {
                throw MP4InspectionError.malformed("truncated hdlr box")
            }
            let handler = try fourCC(in: data, at: handlerBox.payload.lowerBound + 8)
            guard handler == "vide" || handler == "soun" else { continue }

            guard let editContainer = trackChildren.first(where: { $0.type == "edts" }) else {
                throw MP4InspectionError.malformed("edts box not found for \(handler)")
            }
            let editChildren = try mp4Boxes(in: data, range: editContainer.payload)
            guard let editList = editChildren.first(where: { $0.type == "elst" }) else {
                throw MP4InspectionError.malformed("elst box not found for \(handler)")
            }
            let emptyDuration = try initialEmptyEditDuration(in: data, editList: editList)
            result[handler] = Double(emptyDuration) / Double(timescale)
        }
        return result
    }

    private func movieTimescale(in data: Data, header: MP4Box) throws -> UInt32 {
        guard !header.payload.isEmpty else {
            throw MP4InspectionError.malformed("truncated mvhd box")
        }
        let version = try byte(in: data, at: header.payload.lowerBound)
        let offset: Int
        switch version {
        case 0: offset = header.payload.lowerBound + 12
        case 1: offset = header.payload.lowerBound + 20
        default: throw MP4InspectionError.malformed("unsupported mvhd version")
        }
        guard offset >= header.payload.lowerBound,
              header.payload.upperBound - offset >= 4 else {
            throw MP4InspectionError.malformed("truncated mvhd timescale")
        }
        let timescale = try uint32(in: data, at: offset)
        guard timescale > 0 else {
            throw MP4InspectionError.malformed("invalid movie timescale")
        }
        return timescale
    }

    private func initialEmptyEditDuration(in data: Data, editList: MP4Box) throws -> UInt64 {
        guard editList.payload.count >= 8 else {
            throw MP4InspectionError.malformed("truncated elst header")
        }
        let version = try byte(in: data, at: editList.payload.lowerBound)
        let entryCount = try uint32(in: data, at: editList.payload.lowerBound + 4)
        guard entryCount > 0 else {
            throw MP4InspectionError.malformed("elst has no entries")
        }
        let entryOffset = editList.payload.lowerBound + 8
        let entrySize: Int
        let duration: UInt64
        let mediaTime: Int64
        switch version {
        case 0:
            entrySize = 12
            guard editList.payload.upperBound - entryOffset >= entrySize else {
                throw MP4InspectionError.malformed("truncated version 0 elst entry")
            }
            duration = UInt64(try uint32(in: data, at: entryOffset))
            mediaTime = Int64(Int32(bitPattern: try uint32(in: data, at: entryOffset + 4)))
        case 1:
            entrySize = 20
            guard editList.payload.upperBound - entryOffset >= entrySize else {
                throw MP4InspectionError.malformed("truncated version 1 elst entry")
            }
            duration = try uint64(in: data, at: entryOffset)
            mediaTime = Int64(bitPattern: try uint64(in: data, at: entryOffset + 8))
        default:
            throw MP4InspectionError.malformed("unsupported elst version")
        }
        let declaredBytes = UInt64(entryCount) * UInt64(entrySize)
        guard declaredBytes <= UInt64(editList.payload.upperBound - entryOffset) else {
            throw MP4InspectionError.malformed("truncated elst entries")
        }
        return mediaTime == -1 ? duration : 0
    }

    private func mp4Boxes(in data: Data, range: Range<Int>) throws -> [MP4Box] {
        guard range.lowerBound >= 0, range.upperBound <= data.count else {
            throw MP4InspectionError.malformed("box range is outside the file")
        }
        var boxes: [MP4Box] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            let remaining = range.upperBound - offset
            guard remaining >= 8 else {
                throw MP4InspectionError.malformed("truncated box header")
            }
            let size32 = try uint32(in: data, at: offset)
            let type = try fourCC(in: data, at: offset + 4)
            let headerSize: Int
            let boxSize: UInt64
            if size32 == 1 {
                headerSize = 16
                guard remaining >= headerSize else {
                    throw MP4InspectionError.malformed("truncated extended-size \(type) box")
                }
                boxSize = try uint64(in: data, at: offset + 8)
            } else if size32 == 0 {
                headerSize = 8
                boxSize = UInt64(remaining)
            } else {
                headerSize = 8
                boxSize = UInt64(size32)
            }
            guard boxSize >= UInt64(headerSize), boxSize <= UInt64(remaining) else {
                throw MP4InspectionError.malformed("invalid \(type) box size")
            }
            let end = offset + Int(boxSize)
            boxes.append(MP4Box(type: type, payload: (offset + headerSize)..<end))
            offset = end
        }
        return boxes
    }

    private func byte(in data: Data, at offset: Int) throws -> UInt8 {
        guard offset >= 0, offset < data.count else {
            throw MP4InspectionError.malformed("truncated byte")
        }
        return data[offset]
    }

    private func uint32(in data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, data.count - offset >= 4 else {
            throw MP4InspectionError.malformed("truncated UInt32")
        }
        return data[offset..<(offset + 4)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }

    private func uint64(in data: Data, at offset: Int) throws -> UInt64 {
        guard offset >= 0, data.count - offset >= 8 else {
            throw MP4InspectionError.malformed("truncated UInt64")
        }
        return data[offset..<(offset + 8)].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
    }

    private func fourCC(in data: Data, at offset: Int) throws -> String {
        guard offset >= 0, data.count - offset >= 4 else {
            throw MP4InspectionError.malformed("truncated FourCC")
        }
        return String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
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

final class FileStoreAudioOutputTests: XCTestCase {
    func testOutputLocationsUseWAVExtensions() throws {
        let locations = try FileStore().outputLocations(
            for: URL(string: "https://example.com/audio.m3u8")!,
            format: .wav
        )
        defer {
            try? FileManager.default.removeItem(at: locations.temporary)
            try? FileManager.default.removeItem(at: locations.final)
        }
        XCTAssertEqual(locations.final.pathExtension, "wav")
        XCTAssertTrue(locations.temporary.lastPathComponent.hasSuffix(".part.wav"))
    }

    func testStartupCleanupRemovesIncompleteMP4AndWAVOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FileStoreCleanupTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = root.appendingPathComponent(".audio.part.wav")
        let mp4 = root.appendingPathComponent(".video.part.mp4")
        let keep = root.appendingPathComponent("keep.wav")
        XCTAssertTrue(FileManager.default.createFile(atPath: wav.path, contents: Data([1])))
        XCTAssertTrue(FileManager.default.createFile(atPath: mp4.path, contents: Data([2])))
        XCTAssertTrue(FileManager.default.createFile(atPath: keep.path, contents: Data([3])))

        try FileStore.cleanupIncompleteExports(in: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mp4.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
    }

    func testStartupCleanupRemovesOnlyUUIDNamedAbandonedJobs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FileStoreJobCleanupTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let abandoned = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let unrelated = root.appendingPathComponent("keep", isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: abandoned.appendingPathComponent("content.key").path,
            contents: Data(repeating: 9, count: 16)
        ))

        try FileStore.cleanupAbandonedJobs(in: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
