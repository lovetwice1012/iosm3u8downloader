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

    func testRejectsSampleAES() {
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://asset"
        #EXTINF:6,
        segment.ts
        #EXT-X-ENDLIST
        """

        XCTAssertThrowsError(
            try PlaylistParser.parse(text: text, effectiveURL: URL(string: "https://example.com/v.m3u8")!)
        )
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
