import XCTest
@testable import HLSDownloader

final class URIResolverTests: XCTestCase {
    private let base = URL(string: "https://a.example/x/y/index.m3u8?token=secret")!

    func testResolvesPathFormsAgainstPlaylistURL() throws {
        XCTAssertEqual(
            try URIResolver.resolve("seg.ts", relativeTo: base).primary.absoluteString,
            "https://a.example/x/y/seg.ts"
        )
        XCTAssertEqual(
            try URIResolver.resolve("../v/seg.ts", relativeTo: base).primary.absoluteString,
            "https://a.example/x/v/seg.ts"
        )
        XCTAssertEqual(
            try URIResolver.resolve("/root/seg.ts", relativeTo: base).primary.absoluteString,
            "https://a.example/root/seg.ts"
        )
        XCTAssertEqual(
            try URIResolver.resolve("//cdn.example/s.ts", relativeTo: base).primary.absoluteString,
            "https://cdn.example/s.ts"
        )
    }

    func testAddsSameOriginQueryOnlyAsFallback() throws {
        let resolved = try URIResolver.resolve("seg.ts", relativeTo: base)
        XCTAssertNil(resolved.primary.query)
        XCTAssertEqual(resolved.sameOriginQueryFallback?.query, "token=secret")

        let crossOrigin = try URIResolver.resolve("//cdn.example/seg.ts", relativeTo: base)
        XCTAssertNil(crossOrigin.sameOriginQueryFallback)
    }

    func testKeepsExplicitChildQuery() throws {
        let resolved = try URIResolver.resolve("seg.ts?child=1", relativeTo: base)
        XCTAssertEqual(resolved.primary.query, "child=1")
        XCTAssertNil(resolved.sameOriginQueryFallback)
    }

    func testDecodesJavaScriptAndHTMLEscapes() throws {
        let raw = #"https:\/\/a.example\/v.m3u8?token\u003Dabc\u0026part\u003D1&amp;next=2"#
        let resolved = try URIResolver.resolve(raw, relativeTo: base)
        XCTAssertEqual(
            resolved.primary.absoluteString,
            "https://a.example/v.m3u8?token=abc&part=1&next=2"
        )
    }
}
