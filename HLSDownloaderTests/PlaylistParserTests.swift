import XCTest
@testable import HLSDownloader

final class PlaylistParserTests: XCTestCase {
    func testSelectsAndResolvesMasterResources() throws {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="ja",NAME="日本語",DEFAULT=YES,URI="audio/ja.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,AUDIO="ja"
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=3200000,RESOLUTION=1920x1080,AUDIO="ja"
        /high/index.m3u8
        """
        let base = URL(string: "https://example.com/path/master.m3u8")!

        guard case .master(let master) = try PlaylistParser.parse(text: text, effectiveURL: base) else {
            return XCTFail("master playlistではありません")
        }
        XCTAssertEqual(master.variants.count, 2)
        XCTAssertEqual(master.variants[0].url.primary.absoluteString, "https://example.com/path/low/index.m3u8")
        XCTAssertEqual(master.variants[1].url.primary.absoluteString, "https://example.com/high/index.m3u8")
        XCTAssertEqual(master.renditions.first?.url?.primary.absoluteString, "https://example.com/path/audio/ja.m3u8")
    }

    func testResolutionCatalogGroupsDuplicateResolutionsAndSelectsRequestedQuality() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360
        360.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1800000,AVERAGE-BANDWIDTH=1500000,RESOLUTION=1280x720
        720.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=3200000,RESOLUTION=1920x1080
        1080-a.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=4500000,AVERAGE-BANDWIDTH=4000000,RESOLUTION=1920x1080
        1080-b.m3u8
        """
        let base = try XCTUnwrap(URL(string: "https://example.com/master.m3u8"))
        guard case .master(let master) = try PlaylistParser.parse(text: text, effectiveURL: base) else {
            return XCTFail("master playlist expected")
        }

        let options = HLSResolutionCatalog.options(from: master.variants)
        XCTAssertEqual(options.map(\.resolution.id), ["1920x1080", "1280x720", "640x360"])
        XCTAssertEqual(options.first?.bandwidth, 4_000_000)

        let selected = try HLSResolutionCatalog.selectVariant(
            master.variants,
            preferredResolution: try XCTUnwrap(MediaResolution(width: 1280, height: 720))
        )
        XCTAssertEqual(selected.url.primary.lastPathComponent, "720.m3u8")

        XCTAssertThrowsError(
            try HLSResolutionCatalog.selectVariant(
                master.variants,
                preferredResolution: MediaResolution(width: 3840, height: 2160)
            )
        )
    }

    func testMediaResolutionRejectsMalformedOrUnsafeValues() {
        XCTAssertEqual(MediaResolution(hlsAttribute: "1920X1080")?.id, "1920x1080")
        XCTAssertNil(MediaResolution(hlsAttribute: "0x1080"))
        XCTAssertNil(MediaResolution(hlsAttribute: "1920x0"))
        XCTAssertNil(MediaResolution(hlsAttribute: "999999x1080"))
        XCTAssertNil(MediaResolution(hlsAttribute: "1920"))
    }

    func testRejectsMasterWithExcessiveVariantCount() throws {
        let variants = (0...4_096).map { index in
            "#EXT-X-STREAM-INF:BANDWIDTH=1000,RESOLUTION=640x360\n\(index).m3u8"
        }.joined(separator: "\n")
        XCTAssertThrowsError(
            try PlaylistParser.parse(
                text: "#EXTM3U\n\(variants)",
                effectiveURL: try XCTUnwrap(URL(string: "https://example.com/master.m3u8"))
            )
        )
    }

    func testProgressiveMP4PrefixExtractsTrackHeaderResolution() throws {
        func bigEndian32(_ value: UInt32) -> Data {
            Data([
                UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
            ])
        }
        func box(_ type: String, _ payload: Data) -> Data {
            var result = bigEndian32(UInt32(payload.count + 8))
            result.append(Data(type.utf8))
            result.append(payload)
            return result
        }
        var trackHeader = Data([0, 0, 0, 7])
        trackHeader.append(Data(repeating: 0, count: 72))
        trackHeader.append(bigEndian32(UInt32(1920 << 16)))
        trackHeader.append(bigEndian32(UInt32(1080 << 16)))
        let prefix = box("ftyp", Data("isom0000".utf8))
            + box("moov", box("trak", box("tkhd", trackHeader)))

        let resolution = ProgressiveMediaResolutionProbe.detect(
            prefix: prefix,
            container: .isoBaseMedia
        )
        XCTAssertEqual(resolution?.id, "1920x1080")
        XCTAssertNil(ProgressiveMediaResolutionProbe.detect(prefix: prefix, container: .webM))
    }

    func testParsesMediaSequenceMapByteRangesAndAES() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:42
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x0000000000000000000000000000002A
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6.0,
        parts.m4s
        #EXT-X-BYTERANGE:100@20
        #EXTINF:5.5,
        media.bin
        #EXT-X-BYTERANGE:80
        #EXTINF:4.0,
        media.bin
        #EXT-X-ENDLIST
        """
        let base = URL(string: "https://example.com/v/index.m3u8")!

        guard case .media(let playlist) = try PlaylistParser.parse(text: text, effectiveURL: base) else {
            return XCTFail("media playlistではありません")
        }
        XCTAssertTrue(playlist.hasEndList)
        XCTAssertEqual(playlist.segments.count, 3)
        XCTAssertEqual(playlist.segments[0].mediaSequence, 42)
        XCTAssertEqual(playlist.segments[0].initializationMap?.url.primary.lastPathComponent, "init.mp4")
        XCTAssertEqual(playlist.segments[1].byteRange, ByteRange(offset: 20, length: 100))
        XCTAssertEqual(playlist.segments[2].byteRange, ByteRange(offset: 120, length: 80))
        XCTAssertEqual(playlist.segments[0].encryption?.explicitIV?.count, 16)
    }

    func testParsesSampleAESIdentityAndRetainsKeyMetadata() throws {
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT="identity",URI="keys/content.key",IV=0x2A
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6,
        segment.m4s
        #EXT-X-ENDLIST
        """

        guard case .media(let playlist) = try PlaylistParser.parse(
            text: text,
            effectiveURL: URL(string: "https://widevine.sprink.cloud/video/main.m3u8")!
        ) else {
            return XCTFail("media playlist expected")
        }

        let segment = try XCTUnwrap(playlist.segments.first)
        XCTAssertEqual(segment.encryption?.method, .sampleAES)
        XCTAssertEqual(
            segment.encryption?.keyURL.primary.absoluteString,
            "https://widevine.sprink.cloud/video/keys/content.key"
        )
        XCTAssertEqual(segment.encryption?.explicitIV, Data(repeating: 0, count: 15) + Data([0x2A]))
        XCTAssertEqual(segment.initializationMap?.encryption?.method, .sampleAES)
    }

    func testParsesSampleAESIdentityForAlternateAudioPlaylistWithoutExplicitIV() throws {
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="/keys/audio.key"
        #EXT-X-MAP:URI="audio-init.mp4"
        #EXTINF:6,
        audio-1.m4s
        #EXT-X-ENDLIST
        """

        guard case .media(let playlist) = try PlaylistParser.parse(
            text: text,
            effectiveURL: URL(string: "https://widevine.sprink.cloud/audio/ja.m3u8")!
        ) else {
            return XCTFail("media playlist expected")
        }

        let encryption = try XCTUnwrap(playlist.segments.first?.encryption)
        XCTAssertEqual(encryption.method, .sampleAES)
        XCTAssertEqual(encryption.keyURL.primary.absoluteString, "https://widevine.sprink.cloud/keys/audio.key")
        XCTAssertNil(encryption.explicitIV)
    }

    func testSampleAESKeyRotationAndMethodNoneRemainSegmentScoped() throws {
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="key-1.bin"
        #EXTINF:4,
        segment-1.m4s
        #EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT="identity",URI="key-2.bin",IV=0x02
        #EXTINF:4,
        segment-2.m4s
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:4,
        segment-3.m4s
        #EXT-X-ENDLIST
        """

        guard case .media(let playlist) = try PlaylistParser.parse(
            text: text,
            effectiveURL: URL(string: "https://widevine.sprink.cloud/video/stream.m3u8")!
        ) else {
            return XCTFail("media playlist expected")
        }

        XCTAssertEqual(playlist.segments[0].encryption?.keyURL.primary.lastPathComponent, "key-1.bin")
        XCTAssertNil(playlist.segments[0].encryption?.explicitIV)
        XCTAssertEqual(playlist.segments[1].encryption?.keyURL.primary.lastPathComponent, "key-2.bin")
        XCTAssertEqual(playlist.segments[1].encryption?.explicitIV, Data(repeating: 0, count: 15) + Data([0x02]))
        XCTAssertNil(playlist.segments[2].encryption)
    }

    func testSampleAESParserDoesNotApplyDownloadDomainPolicyToKeyCDN() throws {
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="https://keys.example.com/content.key"
        #EXTINF:6,
        segment.m4s
        #EXT-X-ENDLIST
        """

        guard case .media(let playlist) = try PlaylistParser.parse(
            text: text,
            effectiveURL: URL(string: "https://widevine.sprink.cloud/video/main.m3u8")!
        ) else {
            return XCTFail("media playlist expected")
        }
        XCTAssertEqual(
            playlist.segments.first?.encryption?.keyURL.primary.host,
            "keys.example.com"
        )
    }

    func testRejectsFairPlaySampleAES() {
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT="com.apple.streamingkeydelivery",URI="skd://asset"
        #EXTINF:6,
        segment.ts
        #EXT-X-ENDLIST
        """

        XCTAssertThrowsError(
            try PlaylistParser.parse(
                text: text,
                effectiveURL: URL(string: "https://widevine.sprink.cloud/v.m3u8")!
            )
        ) { error in
            guard case HLSError.drmUnsupported = error else {
                return XCTFail("expected drmUnsupported, got \(error)")
            }
        }
    }

    func testRejectsSampleAESCTR() {
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES-CTR,KEYFORMAT="identity",URI="https://widevine.sprink.cloud/content.key"
        #EXTINF:6,
        segment.m4s
        #EXT-X-ENDLIST
        """

        XCTAssertThrowsError(
            try PlaylistParser.parse(
                text: text,
                effectiveURL: URL(string: "https://widevine.sprink.cloud/v.m3u8")!
            )
        ) { error in
            guard case HLSError.drmUnsupported = error else {
                return XCTFail("expected drmUnsupported, got \(error)")
            }
        }
    }

    func testRejectsSegmentWithoutEXTINF() {
        let text = """
        #EXTM3U
        segment.ts
        #EXT-X-ENDLIST
        """

        XCTAssertThrowsError(
            try PlaylistParser.parse(text: text, effectiveURL: URL(string: "https://example.com/v.m3u8")!)
        )
    }

    func testRejectsImplicitByteRangeAfterDifferentResource() {
        let text = """
        #EXTM3U
        #EXT-X-BYTERANGE:100@0
        #EXTINF:4,
        media.bin
        #EXTINF:4,
        other.ts
        #EXT-X-BYTERANGE:100
        #EXTINF:4,
        media.bin
        #EXT-X-ENDLIST
        """

        XCTAssertThrowsError(
            try PlaylistParser.parse(text: text, effectiveURL: URL(string: "https://example.com/v.m3u8")!)
        )
    }

    func testRejectsMapByteRangeWithoutOffset() {
        let text = """
        #EXTM3U
        #EXT-X-MAP:URI="media.mp4",BYTERANGE="100"
        #EXTINF:4,
        media.m4s
        #EXT-X-ENDLIST
        """

        XCTAssertThrowsError(
            try PlaylistParser.parse(text: text, effectiveURL: URL(string: "https://example.com/v.m3u8")!)
        )
    }

    func testRejectsIFrameOnlyPlaylist() {
        let text = """
        #EXTM3U
        #EXT-X-I-FRAMES-ONLY
        #EXTINF:4,
        iframe.ts
        #EXT-X-ENDLIST
        """

        XCTAssertThrowsError(
            try PlaylistParser.parse(text: text, effectiveURL: URL(string: "https://example.com/v.m3u8")!)
        )
    }
}

final class MediaPayloadInspectorTests: XCTestCase {
    func testDetectsTransportStreamByPacketSync() {
        var data = Data(repeating: 0, count: 188 * 3)
        data[0] = 0x47
        data[3] = 0x10
        data[188] = 0x47
        data[191] = 0x10
        data[376] = 0x47
        data[379] = 0x10
        XCTAssertEqual(MediaPayloadInspector.detect(data, mimeType: "text/html"), .transportStream)
    }

    func testDetectsPATAndPMTInitializationPackets() {
        var data = Data(repeating: 0, count: 188 * 2)
        data[0] = 0x47
        data[3] = 0x10
        data[188] = 0x47
        data[189] = 0x01
        data[191] = 0x10
        XCTAssertNil(MediaPayloadInspector.detect(data, mimeType: nil))
        XCTAssertEqual(MediaPayloadInspector.detectInitialization(data), .transportStream)
    }

    func testDetectsISOBaseMediaByBoxType() {
        let data = Data([0, 0, 0, 16]) + Data("ftypisom0000".utf8)
        XCTAssertEqual(MediaPayloadInspector.detect(data, mimeType: nil), .isoBaseMedia)
    }

    func testDetectsProgressiveContainerSignatures() {
        XCTAssertEqual(
            MediaPayloadInspector.detect(Data([0x1a, 0x45, 0xdf, 0xa3, 0x81, 0x00]), mimeType: nil),
            .webM
        )
        XCTAssertEqual(
            MediaPayloadInspector.detect(Data("OggS\0fixture".utf8), mimeType: nil),
            .ogg
        )
        XCTAssertEqual(
            MediaPayloadInspector.detect(Data("RIFF\0\0\0\0WAVEfmt ".utf8), mimeType: nil),
            .wave
        )
        XCTAssertEqual(
            MediaPayloadInspector.detect(Data("fLaCfixture".utf8), mimeType: nil),
            .flac
        )
    }

    func testProgressiveDetectionRequiresMediaMagicNotOnlyAnExtension() {
        let disguisedHTML = Data("<!doctype html><title>sign in</title>".utf8)
        let mp4URL = URL(string: "https://example.com/movie.mp4")!
        XCTAssertTrue(ProgressiveMediaDetector.hasHint(url: mp4URL, mimeType: nil))
        XCTAssertNil(
            ProgressiveMediaDetector.detect(
                prefix: disguisedHTML,
                url: mp4URL,
                mimeType: "video/mp4"
            )
        )

        let webM = Data([0x1a, 0x45, 0xdf, 0xa3, 0x81, 0x00])
        XCTAssertEqual(
            ProgressiveMediaDetector.detect(
                prefix: webM,
                url: URL(string: "https://example.com/download?id=1")!,
                mimeType: "application/octet-stream"
            ),
            .webM
        )
    }

    func testRejectsTruncatedFileTypeBox() {
        let data = Data([0, 0, 0, 8]) + Data("ftyp".utf8)
        XCTAssertNil(MediaPayloadInspector.detect(data, mimeType: "video/mp4"))
    }

    func testRecognizesFragmentThatNeedsInitializationMap() {
        let data = Data([0, 0, 0, 8]) + Data("moof".utf8)
        XCTAssertTrue(MediaPayloadInspector.isFragmentWithoutInitialization(data))
        XCTAssertFalse(MediaPayloadInspector.isInitializationData(data, container: .isoBaseMedia))
    }

    func testAcceptsISOInitializationContainingMovieBox() {
        let data = Data([0, 0, 0, 8]) + Data("moov".utf8)
        XCTAssertTrue(MediaPayloadInspector.isInitializationData(data, container: .isoBaseMedia))
    }

    func testDetectsPackedAACAfterID3Timestamp() {
        let id3 = Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0])
        let adts = Data([0xff, 0xf1, 0x50, 0x80, 0x00, 0xff, 0xfc])
        XCTAssertEqual(MediaPayloadInspector.detect(id3 + adts, mimeType: nil), .aac)
    }

    func testRejectsTruncatedAACHeader() {
        XCTAssertNil(MediaPayloadInspector.detect(Data([0xff, 0xf1, 0x50, 0x80]), mimeType: "audio/aac"))
    }

    func testRejectsHTTP200HTMLBody() {
        let data = Data("<!doctype html><title>login</title>".utf8)
        XCTAssertNil(MediaPayloadInspector.detect(data, mimeType: "text/html"))
        XCTAssertEqual(MediaPayloadInspector.signature(data), "HTML")
    }

    func testDistinguishesEnhancedAC3() {
        var data = Data([0x0b, 0x77, 0, 0, 0, 0x58])
        XCTAssertEqual(MediaPayloadInspector.detect(data, mimeType: nil), .eac3)
        data[5] = 0x50
        XCTAssertEqual(MediaPayloadInspector.detect(data, mimeType: nil), .ac3)
    }
}

final class InitializationMapMemoryBudgetTests: XCTestCase {
    func testAggregateBudgetAcceptsBoundaryAndRejectsNextMap() throws {
        var budget = InitializationMapMemoryBudget()
        for _ in 0..<8 {
            let reserved = try budget.maximumBytesForNextMap()
            XCTAssertEqual(
                reserved,
                InitializationMapMemoryBudget.maximumSingleMapBytes
            )
            try budget.commit(
                byteCount: Int(reserved),
                reservedMaximumBytes: reserved
            )
        }
        XCTAssertEqual(
            budget.committedBytes,
            InitializationMapMemoryBudget.maximumAggregateBytes
        )
        XCTAssertThrowsError(try budget.maximumBytesForNextMap())
    }

    func testFailedFetchDoesNotConsumeReservation() throws {
        var budget = InitializationMapMemoryBudget()
        let firstReservation = try budget.maximumBytesForNextMap()
        let retriedReservation = try budget.maximumBytesForNextMap()

        XCTAssertEqual(firstReservation, retriedReservation)
        XCTAssertEqual(budget.committedBytes, 0)
        XCTAssertEqual(budget.committedMapCount, 0)
    }

    func testMapCountAndSingleMapCapsAreFailClosed() throws {
        var countBudget = InitializationMapMemoryBudget()
        for _ in 0..<InitializationMapMemoryBudget.maximumMapCount {
            let reserved = try countBudget.maximumBytesForNextMap()
            try countBudget.commit(byteCount: 1, reservedMaximumBytes: reserved)
        }
        XCTAssertThrowsError(try countBudget.maximumBytesForNextMap())

        var sizeBudget = InitializationMapMemoryBudget()
        let reserved = try sizeBudget.maximumBytesForNextMap()
        XCTAssertThrowsError(
            try sizeBudget.commit(
                byteCount: Int(reserved) + 1,
                reservedMaximumBytes: reserved
            )
        )
        XCTAssertEqual(sizeBudget.committedBytes, 0)
        XCTAssertEqual(sizeBudget.committedMapCount, 0)
    }
}

final class SegmentMediaMemoryBudgetTests: XCTestCase {
    func testAggregateBoundaryAndReleaseAreFailClosed() async throws {
        let budget = SegmentMediaMemoryBudget()
        let half = SegmentMediaMemoryBudget.maximumInFlightBytes / 2

        let firstOptional = try await budget.tryClaim(byteCount: half)
        let first = try XCTUnwrap(firstOptional)
        let secondOptional = try await budget.tryClaim(byteCount: half)
        let second = try XCTUnwrap(secondOptional)
        let exhaustedBytes = await budget.availableBytes
        XCTAssertEqual(exhaustedBytes, 0)
        let exhaustedClaim = try await budget.tryClaim(byteCount: 1)
        XCTAssertNil(exhaustedClaim)

        await budget.release(first)
        let releasedBytes = await budget.availableBytes
        XCTAssertEqual(releasedBytes, half)
        let replacementOptional = try await budget.tryClaim(byteCount: half)
        let replacement = try XCTUnwrap(replacementOptional)
        let reclaimedBytes = await budget.availableBytes
        XCTAssertEqual(reclaimedBytes, 0)

        await budget.release(second)
        await budget.release(replacement)
        let restoredBytes = await budget.availableBytes
        XCTAssertEqual(
            restoredBytes,
            SegmentMediaMemoryBudget.maximumInFlightBytes
        )
    }

    func testInvalidClaimDoesNotConsumeCapacity() async throws {
        let budget = SegmentMediaMemoryBudget()
        do {
            _ = try await budget.tryClaim(
                byteCount: SegmentMediaMemoryBudget.maximumInFlightBytes + 1
            )
            XCTFail("oversized memory claim should fail")
        } catch {
            // Expected.
        }
        let remainingBytes = await budget.availableBytes
        XCTAssertEqual(
            remainingBytes,
            SegmentMediaMemoryBudget.maximumInFlightBytes
        )
    }
}

private final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var deliveryDelay: TimeInterval = 0
    nonisolated(unsafe) static var onStart: (() -> Void)?
    nonisolated(unsafe) static var onFinish: (() -> Void)?

    static func reset() {
        handler = nil
        deliveryDelay = 0
        onStart = nil
        onFinish = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Self.onStart?()
        let deliver = { [weak self] in
            defer { Self.onFinish?() }
            guard let self else { return }
            do {
                let (response, data) = try handler(self.request)
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
        if Self.deliveryDelay > 0 {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + Self.deliveryDelay,
                execute: DispatchWorkItem(block: deliver)
            )
        } else {
            deliver()
        }
    }

    override func stopLoading() {}
}

private final class ProgressiveRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) -> Int {
        lock.lock()
        requests.append(request)
        let count = requests.count
        lock.unlock()
        return count
    }

    func snapshot() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

final class ProgressiveHTTPDownloadTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testDownloadTaskWritesCompleteProgressiveFileAndEnforcesLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = HTTPClient(configuration: configuration)
        let sourceURL = try XCTUnwrap(URL(string: "https://media.example/movie.mp4"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProgressiveHTTPDownloadTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Data(repeating: 0x5A, count: 384 * 1_024)
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "video/mp4",
                        "Content-Length": String(body.count)
                    ]
                )!,
                body
            )
        }

        let successfulURL = directory.appendingPathComponent("success.media")
        let result = try await client.downloadProgressiveMedia(
            sourceURL,
            to: successfulURL,
            referer: nil,
            maximumBytes: Int64(body.count + 1)
        )
        XCTAssertEqual(result.byteCount, Int64(body.count))
        XCTAssertEqual(try Data(contentsOf: successfulURL), body)

        let rejectedURL = directory.appendingPathComponent("rejected.media")
        do {
            _ = try await client.downloadProgressiveMedia(
                sourceURL,
                to: rejectedURL,
                referer: nil,
                maximumBytes: Int64(body.count - 1)
            )
            XCTFail("A response above the hard download limit must be cancelled")
        } catch let error as HLSError {
            guard case .network = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedURL.path))
    }

    func testOpenEndedRangeRejectsAnIncompleteHTTP206Body() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = HTTPClient(configuration: configuration)
        let sourceURL = try XCTUnwrap(URL(string: "https://media.example/movie.mp4"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProgressiveRangeTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Data(repeating: 0x42, count: 64 * 1_024)
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 206,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "video/mp4",
                        "Content-Range": "bytes 0-\(body.count - 1)/\(body.count + 1)"
                    ]
                )!,
                body
            )
        }

        let output = directory.appendingPathComponent("incomplete.media")
        do {
            _ = try await client.downloadProgressiveMedia(
                sourceURL,
                to: output,
                referer: nil,
                maximumBytes: Int64(body.count + 10)
            )
            XCTFail("An incomplete 206 response must not be published")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testProgressiveRetryRebuildsCookiesAfterServerDeletion() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = HTTPClient(configuration: configuration)
        let sourceURL = try XCTUnwrap(URL(string: "https://media.example/movie.mp4"))
        let cookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "session",
                .value: "secret",
                .domain: "media.example",
                .path: "/",
                .secure: "TRUE"
            ])
        )
        client.storeCookies([cookie])
        let recorder = ProgressiveRequestRecorder()
        let body = Data(repeating: 0x33, count: 32 * 1_024)
        URLProtocolStub.handler = { request in
            let attempt = recorder.append(request)
            if attempt == 1 {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 503,
                        httpVersion: "HTTP/1.1",
                        headerFields: [
                            "Content-Type": "text/plain",
                            "Set-Cookie": "session=deleted; Max-Age=0; Path=/; Secure"
                        ]
                    )!,
                    Data("retry".utf8)
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "video/mp4"]
                )!,
                body
            )
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProgressiveCookieRetry-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await client.downloadProgressiveMedia(
            sourceURL,
            to: directory.appendingPathComponent("result.media"),
            referer: sourceURL,
            maximumBytes: Int64(body.count + 1)
        )

        let requests = recorder.snapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Cookie"), "session=secret")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie"))
    }
}

final class SourceResolverFallbackTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testPlaylistLoadRetriesSignedQueryCandidateAfterHTTP200HTML() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = HTTPClient(configuration: configuration)
        let resolver = SourceResolver(client: client)
        let base = URL(string: "https://cdn.example/path/master.m3u8?token=valid")!
        let candidates = try URIResolver.resolve("variant.m3u8", relativeTo: base)

        URLProtocolStub.handler = { request in
            let isSigned = request.url?.query == "token=valid"
            let body = isSigned
                ? "#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n"
                : "<!doctype html><title>login</title>"
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": isSigned ? "application/vnd.apple.mpegurl" : "text/html"]
            )!
            return (response, Data(body.utf8))
        }

        let document = try await resolver.load(candidates, referer: base)
        XCTAssertTrue(PlaylistParser.isPlaylist(document.text))
        XCTAssertEqual(document.effectiveURL.query, "token=valid")
    }
}

final class SegmentDownloaderFallbackTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testSegmentRetriesSignedQueryCandidateAfterHTTP200HTML() async throws {
        let (downloader, playlist, directory) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        URLProtocolStub.handler = { request in
            let isSigned = request.url?.query == "token=valid"
            return Self.response(
                for: request,
                mimeType: isSigned ? "video/mp2t" : "text/html",
                data: isSigned ? Self.transportStream() : Data("<html>login</html>".utf8)
            )
        }

        let result = try await downloader.download(
            playlist: playlist,
            prefix: "main",
            directory: directory,
            completedBefore: 0,
            totalSegments: 1,
            progress: { _ in }
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].container, .transportStream)
        XCTAssertEqual(result[0].fileURL.pathExtension, "ts")
    }

    func testSegmentReportsInvalidPayloadWhenEveryCandidateIsHTML() async throws {
        let (downloader, playlist, directory) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        URLProtocolStub.handler = { request in
            Self.response(
                for: request,
                mimeType: "text/html",
                data: Data("<!doctype html><title>expired</title>".utf8)
            )
        }

        do {
            _ = try await downloader.download(
                playlist: playlist,
                prefix: "main",
                directory: directory,
                completedBefore: 0,
                totalSegments: 1,
                progress: { _ in }
            )
            XCTFail("HTMLがメディア断片として受理されました")
        } catch let error as HLSError {
            guard case .invalidMediaPayload(let stream, let number, let mimeType, _, let signature) = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
            XCTAssertEqual(stream, "映像")
            XCTAssertEqual(number, 1)
            XCTAssertEqual(mimeType, "text/html")
            XCTAssertEqual(signature, "HTML")
        }
    }

    private func makeFixture() throws -> (SegmentDownloader, MediaPlaylist, URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let downloader = SegmentDownloader(
            client: HTTPClient(configuration: configuration),
            maximumConcurrentDownloads: 1
        )
        let base = URL(string: "https://cdn.example/path/index.m3u8?token=valid")!
        let segment = MediaSegment(
            ordinal: 0,
            mediaSequence: 0,
            duration: 4,
            url: try URIResolver.resolve("segment.ts", relativeTo: base),
            byteRange: nil,
            encryption: nil,
            initializationMap: nil,
            hasDiscontinuity: false
        )
        let playlist = MediaPlaylist(
            effectiveURL: base,
            requestReferer: base,
            segments: [segment],
            hasEndList: true
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (downloader, playlist, directory)
    }

    private static func response(
        for request: URLRequest,
        mimeType: String,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mimeType]
        )!
        return (response, data)
    }

    private static func transportStream() -> Data {
        var data = Data(repeating: 0, count: 188 * 3)
        for offset in stride(from: 0, to: data.count, by: 188) {
            data[offset] = 0x47
            data[offset + 3] = 0x10
        }
        return data
    }
}

final class SampleAESPipelineSecurityTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testAcceptsPublicHTTPSKeyCDNAndKeepsKeyOutOfLocalPlaylist() async throws {
        let key = Data((0..<16).map { UInt8($0) })
        let (downloader, playlist, directory) = try makeFixture(
            keyURL: URL(string: "https://keys.public-cdn.example/content.key")!
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        URLProtocolStub.handler = { request in
            let isKey = request.url?.pathExtension == "key"
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": isKey ? "application/octet-stream" : "video/mp2t"
                ]
            )!
            return (response, isKey ? key : Self.transportStream())
        }

        let result = try await downloader.downloadSampleAESPlaylist(
            playlist: playlist,
            requestedPlaylistURL: playlist.effectiveURL,
            prefix: "main",
            directory: directory,
            completedBefore: 0,
            totalSegments: 1,
            progress: { _ in }
        )
        let localText = try String(contentsOf: result.playlistURL, encoding: .utf8)
        XCTAssertTrue(localText.contains("METHOD=SAMPLE-AES"))
        XCTAssertTrue(localText.contains("main-key-000.key"))
        XCTAssertFalse(localText.contains("keys.public-cdn.example"))
        XCTAssertEqual(result.diagnosticKeys, [key])
    }

    func testRejectsInsecureOrPrivateKeyURLsBeforeFetching() async throws {
        let rejected = [
            "http://keys.example/content.key",
            "https://user:password@keys.example/content.key",
            "https://localhost/content.key",
            "https://10.0.0.1/content.key"
        ]
        URLProtocolStub.handler = { request in
            XCTFail("Unsafe key URL was fetched: \(String(describing: request.url))")
            throw URLError(.unsupportedURL)
        }

        for value in rejected {
            let (downloader, playlist, directory) = try makeFixture(
                keyURL: try XCTUnwrap(URL(string: value))
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                _ = try await downloader.downloadSampleAESPlaylist(
                    playlist: playlist,
                    requestedPlaylistURL: playlist.effectiveURL,
                    prefix: "main",
                    directory: directory,
                    completedBefore: 0,
                    totalSegments: 1,
                    progress: { _ in }
                )
                XCTFail("Accepted unsafe key URL: \(value)")
            } catch let error as HLSError {
                guard case .drmUnsupported = error else {
                    return XCTFail("Unexpected error for \(value): \(error)")
                }
            }
        }
    }

    func testRejectsKeyRedirectDowngrade() async throws {
        let (downloader, playlist, directory) = try makeFixture(
            keyURL: URL(string: "https://keys.example/content.key")!
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: URL(string: "http://keys.example/content.key")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/octet-stream"]
            )!
            return (response, Data(repeating: 7, count: 16))
        }

        do {
            _ = try await downloader.downloadSampleAESPlaylist(
                playlist: playlist,
                requestedPlaylistURL: playlist.effectiveURL,
                prefix: "main",
                directory: directory,
                completedBefore: 0,
                totalSegments: 1,
                progress: { _ in }
            )
            XCTFail("Accepted an HTTPS-to-HTTP key redirect")
        } catch let error as HLSError {
            guard case .invalidAESKey = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsKeyRedirectToPrivateOrLocalDestination() async throws {
        let rejectedEffectiveURLs = [
            URL(string: "https://localhost/content.key")!,
            URL(string: "https://10.0.0.1/content.key")!
        ]

        for effectiveURL in rejectedEffectiveURLs {
            let (downloader, playlist, directory) = try makeFixture(
                keyURL: URL(string: "https://keys.example/content.key")!
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            URLProtocolStub.handler = { request in
                let response = HTTPURLResponse(
                    url: effectiveURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/octet-stream"]
                )!
                return (response, Data(repeating: 7, count: 16))
            }

            do {
                _ = try await downloader.downloadSampleAESPlaylist(
                    playlist: playlist,
                    requestedPlaylistURL: playlist.effectiveURL,
                    prefix: "main",
                    directory: directory,
                    completedBefore: 0,
                    totalSegments: 1,
                    progress: { _ in }
                )
                XCTFail("Accepted a key redirect to \(effectiveURL.host ?? "private host")")
            } catch let error as HLSError {
                guard case .invalidAESKey = error else {
                    return XCTFail("Unexpected error for \(effectiveURL): \(error)")
                }
            }
        }
    }

    func testPreservesTransportStreamKeyRotationAndMethodNone() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let downloader = SegmentDownloader(
            client: HTTPClient(configuration: configuration),
            maximumConcurrentDownloads: 2
        )
        let allowed = URL(string: "https://widevine.sprink.cloud/media.m3u8")!
        let keyURLs = [1, 2].map {
            URLCandidates(
                primary: URL(string: "https://keys.example/key\($0).key")!,
                sameOriginQueryFallback: nil
            )
        }
        let encryptions = keyURLs.map {
            EncryptionDescriptor(method: .sampleAES, keyURL: $0, explicitIV: nil)
        }
        let segments = [encryptions[0], nil, encryptions[1]].enumerated().map { index, encryption in
            MediaSegment(
                ordinal: index,
                mediaSequence: UInt64(index),
                duration: 1,
                url: URLCandidates(
                    primary: URL(string: "https://media.example/\(index).ts")!,
                    sameOriginQueryFallback: nil
                ),
                byteRange: nil,
                encryption: encryption,
                initializationMap: nil,
                hasDiscontinuity: false
            )
        }
        let playlist = MediaPlaylist(
            effectiveURL: allowed,
            requestReferer: allowed,
            segments: segments,
            hasEndList: true
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SampleAESRotationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        URLProtocolStub.handler = { request in
            let path = request.url!.path
            let data: Data
            let mimeType: String
            if path.hasSuffix("key1.key") {
                data = Data(repeating: 1, count: 16)
                mimeType = "application/octet-stream"
            } else if path.hasSuffix("key2.key") {
                data = Data(repeating: 2, count: 16)
                mimeType = "application/octet-stream"
            } else {
                data = Self.transportStream()
                mimeType = "video/mp2t"
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": mimeType]
                )!,
                data
            )
        }

        let result = try await downloader.downloadSampleAESPlaylist(
            playlist: playlist,
            requestedPlaylistURL: allowed,
            prefix: "main",
            directory: directory,
            completedBefore: 0,
            totalSegments: 3,
            progress: { _ in }
        )
        let text = try String(contentsOf: result.playlistURL, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "METHOD=SAMPLE-AES").count - 1, 2)
        XCTAssertTrue(text.contains("#EXT-X-KEY:METHOD=NONE"))
        XCTAssertTrue(text.contains("main-key-000.key"))
        XCTAssertTrue(text.contains("main-key-001.key"))
        XCTAssertEqual(Set(result.diagnosticKeys).count, 2)
    }

    func testRejectsFMP4KeyRotationBeforeComposition() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let downloader = SegmentDownloader(
            client: HTTPClient(configuration: configuration),
            maximumConcurrentDownloads: 2
        )
        let allowed = URL(string: "https://widevine.sprink.cloud/media.m3u8")!
        let encryptions = [1, 2].map { number in
            EncryptionDescriptor(
                method: .sampleAES,
                keyURL: URLCandidates(
                    primary: URL(string: "https://keys.example/key\(number).key")!,
                    sameOriginQueryFallback: nil
                ),
                explicitIV: nil
            )
        }
        let map = InitializationMap(
            url: URLCandidates(
                primary: URL(string: "https://media.example/init.mp4")!,
                sameOriginQueryFallback: nil
            ),
            byteRange: nil,
            encryption: encryptions[0]
        )
        let segments = encryptions.enumerated().map { index, encryption in
            MediaSegment(
                ordinal: index,
                mediaSequence: UInt64(index),
                duration: 1,
                url: URLCandidates(
                    primary: URL(string: "https://media.example/\(index).m4s")!,
                    sameOriginQueryFallback: nil
                ),
                byteRange: nil,
                encryption: encryption,
                initializationMap: map,
                hasDiscontinuity: false
            )
        }
        let playlist = MediaPlaylist(
            effectiveURL: allowed,
            requestReferer: allowed,
            segments: segments,
            hasEndList: true
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SampleAESFMP4RotationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        URLProtocolStub.handler = { request in
            let path = request.url!.path
            let data: Data
            if path.hasSuffix(".key") {
                data = Data(repeating: path.contains("key1") ? 1 : 2, count: 16)
            } else if path.hasSuffix("init.mp4") {
                data = Data([0, 0, 0, 8]) + Data("moov".utf8)
            } else {
                data = Data([0, 0, 0, 8]) + Data("moof".utf8)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/octet-stream"]
                )!,
                data
            )
        }

        do {
            _ = try await downloader.downloadSampleAESPlaylist(
                playlist: playlist,
                requestedPlaylistURL: allowed,
                prefix: "main",
                directory: directory,
                completedBefore: 0,
                totalSegments: 2,
                progress: { _ in }
            )
            XCTFail("Accepted fMP4 SAMPLE-AES key rotation")
        } catch let error as HLSError {
            guard case .drmUnsupported(let detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("fMP4 key rotation"))
        }
    }

    func testRejectsMixedSampleAESRenditionEncryptionAtPlanBoundary() throws {
        let allowed = URL(string: "https://widevine.sprink.cloud/media.m3u8")!
        let sample = try Self.playlist(
            effectiveURL: allowed,
            keyURL: URL(string: "https://keys.example/key")!
        )
        let clear = try Self.playlist(effectiveURL: allowed, keyURL: nil)
        let prepared = PreparedDownloadPlan(
            plan: DownloadPlan(sourceURL: allowed, main: sample, audio: clear),
            mainRequestedURL: allowed,
            audioRequestedURL: allowed
        )

        XCTAssertThrowsError(try prepared.validateSampleAESPermit()) { error in
            guard case HLSError.drmUnsupported(let detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(detail, "mixed SAMPLE-AES rendition encryption")
        }
    }

    func testSampleAESPermitRequiresAllowedRequestedAndEffectivePlaylistURLs() throws {
        let allowed = URL(string: "https://widevine.sprink.cloud/media.m3u8")!
        let denied = URL(string: "https://example.com/media.m3u8")!
        let keyURL = URL(string: "https://keys.example/content.key")!
        let allowedPlaylist = try Self.playlist(effectiveURL: allowed, keyURL: keyURL)

        let accepted = PreparedDownloadPlan(
            plan: DownloadPlan(sourceURL: allowed, main: allowedPlaylist, audio: nil),
            mainRequestedURL: allowed,
            audioRequestedURL: nil
        )
        XCTAssertNoThrow(try accepted.validateSampleAESPermit())

        let deniedRequested = PreparedDownloadPlan(
            plan: DownloadPlan(sourceURL: allowed, main: allowedPlaylist, audio: nil),
            mainRequestedURL: denied,
            audioRequestedURL: nil
        )
        XCTAssertThrowsError(try deniedRequested.validateSampleAESPermit())

        let deniedEffectivePlaylist = try Self.playlist(effectiveURL: denied, keyURL: keyURL)
        let deniedEffective = PreparedDownloadPlan(
            plan: DownloadPlan(sourceURL: allowed, main: deniedEffectivePlaylist, audio: nil),
            mainRequestedURL: allowed,
            audioRequestedURL: nil
        )
        XCTAssertThrowsError(try deniedEffective.validateSampleAESPermit())
    }

    func testSampleAESPermitAppliesToExternalAudioRequestedAndEffectiveURLs() throws {
        let allowed = URL(string: "https://widevine.sprink.cloud/media.m3u8")!
        let denied = URL(string: "https://example.com/audio.m3u8")!
        let keyURL = URL(string: "https://keys.example/content.key")!
        let main = try Self.playlist(effectiveURL: allowed, keyURL: keyURL)
        let allowedAudio = try Self.playlist(effectiveURL: allowed, keyURL: keyURL)

        let deniedRequested = PreparedDownloadPlan(
            plan: DownloadPlan(sourceURL: allowed, main: main, audio: allowedAudio),
            mainRequestedURL: allowed,
            audioRequestedURL: denied
        )
        XCTAssertThrowsError(try deniedRequested.validateSampleAESPermit())

        let deniedEffectiveAudio = try Self.playlist(effectiveURL: denied, keyURL: keyURL)
        let deniedEffective = PreparedDownloadPlan(
            plan: DownloadPlan(sourceURL: allowed, main: main, audio: deniedEffectiveAudio),
            mainRequestedURL: allowed,
            audioRequestedURL: allowed
        )
        XCTAssertThrowsError(try deniedEffective.validateSampleAESPermit())
    }

    private func makeFixture(
        keyURL: URL
    ) throws -> (SegmentDownloader, MediaPlaylist, URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let downloader = SegmentDownloader(
            client: HTTPClient(configuration: configuration),
            maximumConcurrentDownloads: 1
        )
        let allowed = URL(string: "https://widevine.sprink.cloud/media.m3u8")!
        let playlist = try Self.playlist(effectiveURL: allowed, keyURL: keyURL)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SampleAESPipelineSecurityTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (downloader, playlist, directory)
    }

    private static func playlist(effectiveURL: URL, keyURL: URL?) throws -> MediaPlaylist {
        let encryption = keyURL.map {
            EncryptionDescriptor(
                method: .sampleAES,
                keyURL: URLCandidates(primary: $0, sameOriginQueryFallback: nil),
                explicitIV: nil
            )
        }
        let segment = MediaSegment(
            ordinal: 0,
            mediaSequence: 0,
            duration: 4,
            url: URLCandidates(
                primary: URL(string: "https://media.public-cdn.example/segment.ts")!,
                sameOriginQueryFallback: nil
            ),
            byteRange: nil,
            encryption: encryption,
            initializationMap: nil,
            hasDiscontinuity: false
        )
        return MediaPlaylist(
            effectiveURL: effectiveURL,
            requestReferer: effectiveURL,
            segments: [segment],
            hasEndList: true
        )
    }

    private static func transportStream() -> Data {
        var data = Data(repeating: 0, count: 188 * 3)
        for offset in stride(from: 0, to: data.count, by: 188) {
            data[offset] = 0x47
            data[offset + 3] = 0x10
        }
        return data
    }
}

private final class RequestConcurrencyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRequests = 0
    private var highestActiveRequests = 0

    func started() {
        lock.lock()
        activeRequests += 1
        highestActiveRequests = max(highestActiveRequests, activeRequests)
        lock.unlock()
    }

    func finished() {
        lock.lock()
        activeRequests -= 1
        lock.unlock()
    }

    func maximum() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return highestActiveRequests
    }
}

final class SegmentDownloaderConcurrencyTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testDownloadsSegmentsConcurrentlyAndReturnsPlaylistOrder() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let downloader = SegmentDownloader(
            client: HTTPClient(configuration: configuration),
            maximumConcurrentDownloads: 3
        )
        let counter = RequestConcurrencyCounter()
        URLProtocolStub.deliveryDelay = 0.1
        URLProtocolStub.onStart = { counter.started() }
        URLProtocolStub.onFinish = { counter.finished() }
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "video/mp2t"]
            )!
            var data = Data(repeating: 0, count: 188 * 3)
            for offset in stride(from: 0, to: data.count, by: 188) {
                data[offset] = 0x47
                data[offset + 3] = 0x10
            }
            return (response, data)
        }

        let base = URL(string: "https://cdn.example/parallel/index.m3u8")!
        let segments = (0..<6).map { ordinal in
            MediaSegment(
                ordinal: ordinal,
                mediaSequence: UInt64(ordinal),
                duration: 1,
                url: URLCandidates(
                    primary: URL(string: "https://cdn.example/parallel/\(ordinal).ts")!,
                    sameOriginQueryFallback: nil
                ),
                byteRange: nil,
                encryption: nil,
                initializationMap: nil,
                hasDiscontinuity: false
            )
        }
        let playlist = MediaPlaylist(
            effectiveURL: base,
            requestReferer: base,
            segments: segments,
            hasEndList: true
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SegmentDownloaderConcurrencyTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await downloader.download(
            playlist: playlist,
            prefix: "main",
            directory: directory,
            completedBefore: 0,
            totalSegments: segments.count,
            progress: { _ in }
        )

        XCTAssertGreaterThan(counter.maximum(), 1)
        XCTAssertLessThanOrEqual(counter.maximum(), 3)
        XCTAssertEqual(result.map(\.source.ordinal), Array(0..<6))
    }
}
