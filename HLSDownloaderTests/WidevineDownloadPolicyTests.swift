import XCTest
@testable import HLSDownloader

final class WidevineDownloadPolicyTests: XCTestCase {
    func testAllowsOnlyExactConfiguredHost() throws {
        XCTAssertTrue(isDownloadableWidevineDomain(try XCTUnwrap(URL(string: "https://widevine.sprink.cloud/video/manifest.mpd"))))
        XCTAssertTrue(isDownloadableWidevineDomain(try XCTUnwrap(URL(string: "https://WIDEVINE.SPRINK.CLOUD:443/video/manifest.mpd"))))

        let rejected = [
            "https://www.widevine.sprink.cloud/video/manifest.mpd",
            "https://widevine.sprink.cloud.example.com/video/manifest.mpd",
            "https://evil-widevine.sprink.cloud/video/manifest.mpd",
            "https://widevine.sprink.cloud./video/manifest.mpd",
            "https://widevine.sprink.cloud.evil.example/video/manifest.mpd",
            "https://widevine.sprink.cloud@evil.example/video/manifest.mpd",
            "https://evil.example/video/widevine.sprink.cloud/manifest.mpd",
            "https://evil.example/video/manifest.mpd?host=widevine.sprink.cloud",
            "https://evil.example/video/manifest.mpd#widevine.sprink.cloud"
        ]

        for value in rejected {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertFalse(isDownloadableWidevineDomain(url), "unexpectedly allowed \(value)")
        }
    }

    func testRejectsURLsWithoutAllowedHostEvenWhenPathContainsIt() throws {
        XCTAssertFalse(isDownloadableWidevineDomain(try XCTUnwrap(URL(string: "/widevine.sprink.cloud/manifest.mpd"))))
        XCTAssertFalse(isDownloadableWidevineDomain(try XCTUnwrap(URL(string: "file:///widevine.sprink.cloud/manifest.mpd"))))
    }

    func testDomainPolicyDoesNotRestrictNonDRMHLSParsing() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/video/master.m3u8"))
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXTINF:4,
        segment.ts
        #EXT-X-ENDLIST
        """

        XCTAssertFalse(isDownloadableWidevineDomain(url))
        guard case .media(let playlist) = try PlaylistParser.parse(text: text, effectiveURL: url) else {
            return XCTFail("DRMなしHLSは従来どおり解析できる必要があります")
        }
        XCTAssertEqual(playlist.segments.count, 1)
        XCTAssertEqual(playlist.segments.first?.url.primary.absoluteString, "https://example.com/video/segment.ts")
    }
}
