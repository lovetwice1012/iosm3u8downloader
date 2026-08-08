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
