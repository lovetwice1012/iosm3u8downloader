import XCTest
import WebKit
@testable import HLSDownloader

final class HTMLMediaExtractorTests: XCTestCase {
    func testExtractsVideoSourcePosterBaseAndEntities() throws {
        let html = #"""
        <!doctype html>
        <html>
          <head>
            <base href="/assets/player/">
            <title> Sample &amp; Movie </title>
          </head>
          <body>
            <video poster="../images/poster.jpg?a=1&amp;b=2" src="main/master.m3u8?x=1&amp;y=2">
              <source TYPE='application/vnd.apple.mpegurl' SRC='../api/manifest?id=3&amp;k=4'>
            </video>
          </body>
        </html>
        """#

        let result = HTMLMediaExtractor.extract(from: html)
        XCTAssertEqual(result.baseHref, "/assets/player/")
        XCTAssertEqual(result.title, "Sample & Movie")
        XCTAssertEqual(result.media.count, 2)
        XCTAssertEqual(result.media[0].rawURL, "main/master.m3u8?x=1&y=2")
        XCTAssertEqual(result.media[0].rawPosterURL, "../images/poster.jpg?a=1&b=2")
        XCTAssertEqual(result.media[0].origin, .video)
        XCTAssertEqual(result.media[1].rawURL, "../api/manifest?id=3&k=4")
        XCTAssertEqual(result.media[1].rawPosterURL, "../images/poster.jpg?a=1&b=2")
        XCTAssertEqual(result.media[1].origin, .source)
    }

    func testHandlesCaseUnquotedAttributesQuoteGreaterThanAndSrcdoc() throws {
        let html = #"""
        <VIDEO POSTER='/p?caption=a>b'>
          <SOURCE SRC=//cdn.example/video.m3u8?x=1&amp;y=2 TYPE=application/x-mpegURL>
        </VIDEO>
        <IFRAME title='nested player' srcdoc="&lt;video src=&quot;/inside.m3u8&quot;&gt;&lt;/video&gt;"></IFRAME>
        """#

        let result = HTMLMediaExtractor.extract(from: html)
        XCTAssertEqual(result.media.map(\.rawURL), ["//cdn.example/video.m3u8?x=1&y=2"])
        XCTAssertEqual(result.media.first?.rawURL, "//cdn.example/video.m3u8?x=1&y=2")
        XCTAssertEqual(result.media.first?.rawPosterURL, "/p?caption=a>b")
        XCTAssertEqual(result.frames.count, 1)
        XCTAssertEqual(result.frames[0].title, "nested player")
        XCTAssertEqual(result.frames[0].sourceDocument, #"<video src="/inside.m3u8"></video>"#)
    }

    func testLooseFallbackKeepsTextAndAttributeConfigsWithoutLeakingSrcdoc() throws {
        let html = #"""
        <div data-player='{"file":"/attribute.m3u8"}'></div>
        <textarea>{"file":"/text.m3u8"}</textarea>
        <iframe srcdoc="&lt;video src=&quot;/inside.m3u8&quot;&gt;&lt;/video&gt;"></iframe>
        """#

        let result = HTMLMediaExtractor.extract(from: html)

        XCTAssertEqual(result.media.map(\.rawURL), ["/attribute.m3u8", "/text.m3u8"])
        XCTAssertEqual(result.frames.count, 1)
    }

    func testKeepsLazyIframeURLAfterAboutBlankPlaceholder() throws {
        let result = HTMLMediaExtractor.extract(
            from: #"<iframe src="about:blank" data-src="https://player.example/embed/7"></iframe>"#
        )

        XCTAssertEqual(result.frames.map(\.rawURL), ["about:blank", "https://player.example/embed/7"])
    }

    func testSrcdocPresenceSuppressesIframeSrcEvenWhenEmpty() throws {
        let result = HTMLMediaExtractor.extract(
            from: #"<iframe srcdoc="" src="https://ignored.example/player"></iframe>"#
        )

        XCTAssertEqual(result.frames.count, 1)
        XCTAssertEqual(result.frames.first?.sourceDocument, "")
        XCTAssertNil(result.frames.first?.rawURL)
    }

    func testFirstBaseWithEmptyHrefStillWins() throws {
        let result = HTMLMediaExtractor.extract(
            from: #"<base href=""><base href="https://evil.example/"><video src="v.m3u8"></video>"#
        )

        XCTAssertEqual(result.baseHref, "")
    }

    func testRemovesSelfClosingSlashFromUnquotedSourceURL() throws {
        let result = HTMLMediaExtractor.extract(
            from: #"<video><source src=/media/master.m3u8/></video>"#
        )

        XCTAssertEqual(result.media.map(\.rawURL), ["/media/master.m3u8"])
    }

    func testExtractsEscapedInlineManifestWithoutDuplicatingStructuredURL() throws {
        let html = #"""
        <video src="/structured.m3u8"></video>
        <script>
          window.player = { file: "https:\/\/cdn.example\/escaped.m3u8?token\u003Dabc\u0026part\u003D1" };
        </script>
        """#

        let result = HTMLMediaExtractor.extract(from: html)
        XCTAssertEqual(result.media.count, 2)
        XCTAssertEqual(result.media[0].rawURL, "/structured.m3u8")
        XCTAssertEqual(
            result.media[1].rawURL,
            "https://cdn.example/escaped.m3u8?token=abc&part=1"
        )
        XCTAssertEqual(result.media[1].origin, .inlineScript)
    }

    func testRecognizesExtensionlessSourceWithAdditionalHLSMimeTypes() throws {
        let result = HTMLMediaExtractor.extract(
            from: #"<video><source src="/manifest?id=1" type="audio/x-mpegurl"><source src="/manifest?id=2" type="application/mpegurl"></video>"#
        )

        XCTAssertEqual(result.media.map(\.rawURL), ["/manifest?id=1", "/manifest?id=2"])
        XCTAssertEqual(result.media.map(\.kind), [.hls, .hls])
    }

    func testExtractsDASHFromDOMMIMEDataAttributesAndScriptsWithKinds() throws {
        let html = #"""
        <video><source src="/api/manifest?id=1" type="application/dash+xml"></video>
        <div data-mpd="/data/movie.mpd"></div>
        <script>
          const dash = "https://widevine.sprink.cloud/inline/manifest.mpd?token=abc";
          const hls = "/inline/master.m3u8";
        </script>
        """#

        let result = HTMLMediaExtractor.extract(from: html)

        XCTAssertEqual(
            result.media.map(\.rawURL),
            [
                "/api/manifest?id=1",
                "/data/movie.mpd",
                "https://widevine.sprink.cloud/inline/manifest.mpd?token=abc",
                "/inline/master.m3u8"
            ]
        )
        XCTAssertEqual(result.media.map(\.kind), [.widevineDASH, .widevineDASH, .widevineDASH, .hls])
        XCTAssertEqual(
            HTMLMediaExtractor.extractMPDStrings(from: #"a="/one.mpd";b="/two.MPD?x=1""#),
            ["/one.mpd", "/two.MPD?x=1"]
        )
    }

    func testDecodesSemicolonlessEntityAndDoubleEscapedURL() throws {
        let result = HTMLMediaExtractor.extract(
            from: #"<script>const source="https:\\/\\/cdn\\u002Eexample\\/v\\u002Em3u8?a=1&amp;b=2"</script>"#
        )

        XCTAssertEqual(result.media.first?.rawURL, "https://cdn.example/v.m3u8?a=1&b=2")
        XCTAssertEqual(HTMLMediaExtractor.decodeHTMLEntities("a&amp"), "a&")
    }
}

final class DiagnosticLogTests: XCTestCase {
    func testURLSummaryAndErrorCodeDoNotExposeSecrets() throws {
        let url = try XCTUnwrap(
            URL(string: "https://user:password@secret.example/private/master.m3u8?token=top-secret&quality=high#fragment")
        )
        let rotatedURL = try XCTUnwrap(
            URL(string: "https://secret.example/private/master.m3u8?token=different&quality=low")
        )
        let store = DiagnosticLogStore()
        let summary = DiagnosticPrivacy.urlSummary(url)
        let rotatedSummary = DiagnosticPrivacy.urlSummary(rotatedURL)
        store.record("test", summary)
        store.record("test", "error=\(DiagnosticPrivacy.errorCode(HLSError.network("token=leak")))")
        store.record(
            "test",
            "generic=\(DiagnosticPrivacy.errorCode(NSError(domain: "top-secret.example", code: 7)))"
        )
        store.record(
            "test",
            "media=\(DiagnosticPrivacy.errorSummary(HLSError.invalidMediaPayload(stream: "main", number: 7, mimeType: "video/mp2t; secret=body-secret", byteCount: 123, signature: "body-secret")))"
        )

        let text = store.renderedText()
        XCTAssertTrue(text.contains("ext=m3u8"))
        XCTAssertTrue(text.contains("queryItems=2"))
        XCTAssertTrue(text.contains("error=network"))
        XCTAssertTrue(text.contains("generic=NSError(7)"))
        XCTAssertTrue(text.contains("media=invalidMediaPayload stream=main segment=7 mime=media bytes=123"))
        XCTAssertEqual(summary.split(separator: " ").first, rotatedSummary.split(separator: " ").first)
        for secret in ["user", "password", "secret.example", "private", "top-secret", "quality", "fragment", "token=leak", "body-secret"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
    }

    func testLogIsBoundedAndReportsDroppedEntries() {
        let store = DiagnosticLogStore(capacity: 50, maximumUTF8Bytes: 16 * 1_024)
        for index in 0..<80 {
            store.record("test", "event-\(index)")
        }

        let text = store.renderedText()
        XCTAssertTrue(text.contains("Entries: 50, dropped: 30"))
        XCTAssertFalse(text.contains("event-0\n"))
        XCTAssertTrue(text.contains("event-79"))
    }
}

final class PlaybackProbePayloadParserTests: XCTestCase {
    func testRequiresExactPerSessionMessageNonce() {
        let expected = "0123456789abcdef0123456789abcdef"
        XCTAssertTrue(
            PlaybackProbePayloadParser.hasValidNonce(
                ["nonce": expected],
                expected: expected
            )
        )
        XCTAssertFalse(
            PlaybackProbePayloadParser.hasValidNonce(
                ["nonce": "0123456789abcdef0123456789abcdee"],
                expected: expected
            )
        )
        XCTAssertFalse(
            PlaybackProbePayloadParser.hasValidNonce([:], expected: expected)
        )
    }

    func testParsesOnlyNonSecretLicenseRequestMetadata() throws {
        let payload = try XCTUnwrap(
            PlaybackProbePayloadParser.licensePayload(
                from: [
                    "eventKind": "licenseRequest",
                    "url": "https://license.example/acquire",
                    "method": "post",
                    "contentType": "application/octet-stream; charset=binary",
                    "headerNames": ["Authorization", "X-Playback-Token"],
                    "bodyKind": "binary",
                    "bodyByteCount": NSNumber(value: 512),
                    "source": "emeCorrelatedFetch",
                    "frameToken": "frame-123",
                    "sequence": NSNumber(value: 9),
                    // A compromised page may add arbitrary fields. The parser
                    // has no representation for either value and ignores them.
                    "headerValues": ["Bearer must-not-cross"],
                    "body": "challenge-must-not-cross"
                ]
            )
        )

        XCTAssertEqual(payload.rawURL, "https://license.example/acquire")
        XCTAssertEqual(payload.metadata.method, "POST")
        XCTAssertEqual(payload.metadata.contentType, "application/octet-stream")
        XCTAssertEqual(payload.metadata.headerNames, ["authorization", "x-playback-token"])
        XCTAssertEqual(payload.metadata.bodyKind, .binary)
        XCTAssertEqual(payload.metadata.bodyByteCount, 512)
        XCTAssertEqual(payload.metadata.source, .emeCorrelatedFetch)
        XCTAssertEqual(payload.frameToken, "frame-123")
        XCTAssertEqual(payload.sequence, 9)
        XCTAssertFalse(String(reflecting: payload).contains("must-not-cross"))
    }

    func testRejectsUnknownBodyKindAndSource() {
        let base: [String: Any] = [
            "eventKind": "licenseRequest",
            "url": "https://license.example/acquire",
            "method": "POST",
            "headerNames": [String](),
            "bodyKind": "binary",
            "bodyByteCount": NSNumber(value: 1),
            "source": "fetch"
        ]
        var unknownBody = base
        unknownBody["bodyKind"] = "protobuf"
        var unknownSource = base
        unknownSource["source"] = "serviceWorker"

        XCTAssertNil(PlaybackProbePayloadParser.licensePayload(from: unknownBody))
        XCTAssertNil(PlaybackProbePayloadParser.licensePayload(from: unknownSource))
    }

    func testNormalizesUntrustedBounds() throws {
        let payload = try XCTUnwrap(
            PlaybackProbePayloadParser.licensePayload(
                from: [
                    "eventKind": "licenseRequest",
                    "url": "https://license.example/acquire",
                    "method": "POST",
                    "headerNames": ["Content-Type"],
                    "bodyKind": "binary",
                    "bodyByteCount": NSNumber(value: Int.max),
                    "source": "xmlHttpRequest",
                    "frameToken": String(repeating: "x", count: 65),
                    "sequence": NSNumber(value: -10)
                ]
            )
        )

        XCTAssertEqual(payload.metadata.bodyByteCount, 16 * 1_024 * 1_024)
        XCTAssertNil(payload.frameToken)
        XCTAssertEqual(payload.sequence, 0)

        var tooManyHeaders: [String: Any] = [
            "eventKind": "licenseRequest",
            "url": "https://license.example/acquire",
            "method": "POST",
            "headerNames": (0...32).map { "x-header-\($0)" },
            "bodyKind": "none",
            "bodyByteCount": NSNumber(value: 0),
            "source": "fetch"
        ]
        XCTAssertNil(PlaybackProbePayloadParser.licensePayload(from: tooManyHeaders))
        tooManyHeaders["headerNames"] = [String]()
        tooManyHeaders["url"] = String(repeating: "x", count: 8_193)
        XCTAssertNil(PlaybackProbePayloadParser.licensePayload(from: tooManyHeaders))
    }
}

private final class DiscoveryURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() {
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class DiscoveryRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func snapshot() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

final class PlaybackCapturePersistenceTests: XCTestCase {
    @MainActor
    func testPlaybackCaptureUsesPersistentWebsiteDataStore() async throws {
        let session = PlaybackCaptureSession(
            url: try XCTUnwrap(URL(string: "https://example.com/login"))
        )

        XCTAssertTrue(session.webView.configuration.websiteDataStore.isPersistent)
        _ = await session.snapshotAndStop()
    }
}

@MainActor
private final class StubDynamicInspector: DynamicPageInspecting {
    let inspection: DynamicPageInspection

    init(inspection: DynamicPageInspection) {
        self.inspection = inspection
    }

    func inspect(url: URL, seedCookies: [HTTPCookie]) async -> DynamicPageInspection {
        inspection
    }
}

final class SourceDiscoveryTests: XCTestCase {
    override func tearDown() {
        DiscoveryURLProtocolStub.reset()
        super.tearDown()
    }

    func testMarksDirectPlaylistForImmediateDownload() async throws {
        let resolver = makeResolver()
        DiscoveryURLProtocolStub.handler = { request in
            Self.response(
                request,
                body: "#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n",
                mimeType: "application/vnd.apple.mpegurl"
            )
        }

        let discovery = try await resolver.discover(input: "https://media.example/master.m3u8")
        XCTAssertTrue(discovery.isDirectPlaylist)
        XCTAssertEqual(discovery.candidates.count, 1)
        XCTAssertNotNil(discovery.candidates[0].document)
        XCTAssertEqual(discovery.candidates[0].origin, .direct)
        XCTAssertEqual(discovery.candidates[0].kind, .hls)
    }

    func testAcceptsDirectWidevineMPDOnlyOnDownloadableDomain() async throws {
        let recorder = DiscoveryRequestRecorder()
        let resolver = makeResolver()
        DiscoveryURLProtocolStub.handler = { request in
            recorder.append(request)
            return Self.response(request, body: Self.widevineMPD, mimeType: "application/dash+xml")
        }

        let discovery = try await resolver.discover(
            input: "https://widevine.sprink.cloud/video/manifest.mpd"
        )

        XCTAssertTrue(discovery.isDirectPlaylist)
        XCTAssertEqual(discovery.candidates.count, 1)
        XCTAssertEqual(discovery.candidates.first?.kind, .widevineDASH)
        XCTAssertEqual(
            discovery.candidates.first?.playlistURL.absoluteString,
            "https://widevine.sprink.cloud/video/manifest.mpd"
        )
        XCTAssertNotNil(discovery.candidates.first?.document)
        XCTAssertEqual(recorder.snapshot().count, 1)
    }

    func testRejectsDirectWidevineMPDOnOtherDomainAfterContentValidation() async throws {
        let recorder = DiscoveryRequestRecorder()
        let resolver = makeResolver()
        DiscoveryURLProtocolStub.handler = { request in
            recorder.append(request)
            return Self.response(request, body: Self.widevineMPD, mimeType: "application/dash+xml")
        }

        do {
            _ = try await resolver.discover(input: "https://example.com/video/manifest.mpd")
            XCTFail("許可ドメイン外のMPDを候補化してはいけません")
        } catch let error as HLSError {
            guard case .drmUnsupported = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(recorder.snapshot().count, 1)
    }

    func testMPDExtensionContainingHLSRemainsDownloadableOnOtherDomain() async throws {
        let resolver = makeResolver()
        DiscoveryURLProtocolStub.handler = { request in
            Self.response(
                request,
                body: "#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n",
                mimeType: "application/vnd.apple.mpegurl"
            )
        }

        let discovery = try await resolver.discover(input: "https://example.com/video/manifest.mpd")

        XCTAssertEqual(discovery.candidates.count, 1)
        XCTAssertEqual(discovery.candidates.first?.kind, .hls)
        XCTAssertTrue(discovery.isDirectPlaylist)
    }

    func testMPDExtensionContainingHTMLStillDiscoversHLSOnOtherDomain() async throws {
        let recorder = DiscoveryRequestRecorder()
        let resolver = makeResolver()
        DiscoveryURLProtocolStub.handler = { request in
            recorder.append(request)
            return Self.response(
                request,
                body: #"<video src="/video/actual-master.m3u8"></video>"#,
                mimeType: "text/html"
            )
        }

        let discovery = try await resolver.discover(input: "https://example.com/player/page.mpd")

        XCTAssertEqual(discovery.candidates.count, 1)
        XCTAssertEqual(discovery.candidates.first?.kind, .hls)
        XCTAssertEqual(
            discovery.candidates.first?.playlistURL.absoluteString,
            "https://example.com/video/actual-master.m3u8"
        )
        XCTAssertEqual(recorder.snapshot().count, 1)
    }

    func testRejectsDirectWidevineMPDRedirectedOutsideDownloadableDomain() async throws {
        let resolver = makeResolver()
        DiscoveryURLProtocolStub.handler = { request in
            let redirectedURL = URL(string: "https://example.com/video/redirected.mpd")!
            let response = HTTPURLResponse(
                url: redirectedURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/dash+xml"]
            )!
            return (response, Data(Self.widevineMPD.utf8))
        }

        do {
            _ = try await resolver.discover(
                input: "https://widevine.sprink.cloud/video/manifest.mpd"
            )
            XCTFail("許可ドメイン外へ到達したMPDを候補化してはいけません")
        } catch let error as HLSError {
            guard case .drmUnsupported = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testResolvesCandidateAndPosterAgainstFirstBaseWithoutFetchingManifest() async throws {
        let recorder = DiscoveryRequestRecorder()
        let resolver = makeResolver()
        DiscoveryURLProtocolStub.handler = { request in
            recorder.append(request)
            let html = #"""
            <base href="/assets/player/">
            <base href="https://evil.example/">
            <meta property="og:image" content="../fallback.jpg">
            <video title="本編" poster="../poster.jpg" src="master/index.m3u8?quality=high&amp;token=secret"></video>
            """#
            return Self.response(request, body: html, mimeType: "text/html")
        }

        let discovery = try await resolver.discover(input: "https://site.example/watch/42?session=page")
        XCTAssertFalse(discovery.isDirectPlaylist)
        XCTAssertEqual(discovery.candidates.count, 1)
        let candidate = try XCTUnwrap(discovery.candidates.first)
        XCTAssertEqual(
            candidate.playlistURL.absoluteString,
            "https://site.example/assets/player/master/index.m3u8?quality=high&token=secret"
        )
        XCTAssertEqual(candidate.thumbnailURL?.absoluteString, "https://site.example/assets/poster.jpg")
        XCTAssertEqual(candidate.title, "本編")
        XCTAssertEqual(candidate.origin, .video)
        XCTAssertNil(candidate.document)
        XCTAssertEqual(recorder.snapshot().count, 1, "候補は選択前に自動GETしません")
    }

    func testValidatesStaticWidevineMPDAndKeepsHLSBehaviorLazy() async throws {
        let recorder = DiscoveryRequestRecorder()
        let resolver = makeResolver()
        DiscoveryURLProtocolStub.handler = { request in
            recorder.append(request)
            switch request.url?.host {
            case "site.example":
                return Self.response(
                    request,
                    body: #"<video src="https://cdn.example/master.m3u8"></video><source src="https://widevine.sprink.cloud/video/manifest.mpd" type="application/dash+xml">"#,
                    mimeType: "text/html"
                )
            case "widevine.sprink.cloud":
                return Self.response(request, body: Self.widevineMPD, mimeType: "application/dash+xml")
            default:
                throw URLError(.fileDoesNotExist)
            }
        }

        let discovery = try await resolver.discover(input: "https://site.example/watch")

        XCTAssertEqual(discovery.candidates.map(\.kind), [.hls, .widevineDASH])
        XCTAssertNil(discovery.candidates[0].document)
        XCTAssertNotNil(discovery.candidates[1].document)
        XCTAssertEqual(recorder.snapshot().count, 2, "HLSは候補選択まで取得せずMPDだけを検証します")
    }

    func testRejectsStaticWidevineMPDOnOtherDomainAfterContentValidation() async throws {
        let recorder = DiscoveryRequestRecorder()
        let diagnostics = DiagnosticLogStore()
        let resolver = makeResolver(diagnostics: diagnostics)
        DiscoveryURLProtocolStub.handler = { request in
            recorder.append(request)
            if request.url?.host == "site.example" {
                return Self.response(
                    request,
                    body: #"<video src="https://example.com/video/manifest.mpd"></video>"#,
                    mimeType: "text/html"
                )
            }
            return Self.response(request, body: Self.widevineMPD, mimeType: "application/dash+xml")
        }

        do {
            _ = try await resolver.discover(input: "https://site.example/watch")
            XCTFail("許可ドメイン外のMPDを候補化してはいけません")
        } catch let error as HLSError {
            guard case .noPlaylistFound = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(recorder.snapshot().count, 2)
        XCTAssertTrue(diagnostics.renderedText().contains("download-domain policy"))
    }

    func testFindsWidevineMPDInsideSameOriginIframe() async throws {
        let resolver = makeResolver()
        DiscoveryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/watch":
                return Self.response(
                    request,
                    body: #"<iframe src="/video/manifest.mpd"></iframe>"#,
                    mimeType: "text/html"
                )
            case "/video/manifest.mpd":
                return Self.response(request, body: Self.widevineMPD, mimeType: "application/dash+xml")
            default:
                throw URLError(.fileDoesNotExist)
            }
        }

        let discovery = try await resolver.discover(input: "https://widevine.sprink.cloud/watch")

        XCTAssertEqual(discovery.candidates.count, 1)
        XCTAssertEqual(discovery.candidates.first?.kind, .widevineDASH)
        XCTAssertEqual(discovery.candidates.first?.origin, .iframe)
        XCTAssertNotNil(discovery.candidates.first?.document)
    }

    func testRejectsWidevineMPDInsideOtherDomainIframe() async throws {
        let diagnostics = DiagnosticLogStore()
        let resolver = makeResolver(diagnostics: diagnostics)
        DiscoveryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/watch":
                return Self.response(
                    request,
                    body: #"<iframe src="/video/manifest.mpd"></iframe>"#,
                    mimeType: "text/html"
                )
            case "/video/manifest.mpd":
                return Self.response(request, body: Self.widevineMPD, mimeType: "application/dash+xml")
            default:
                throw URLError(.fileDoesNotExist)
            }
        }

        do {
            _ = try await resolver.discover(input: "https://example.com/watch")
            XCTFail("許可ドメイン外iframeのWidevine MPDを候補化してはいけません")
        } catch let error as HLSError {
            guard case .noPlaylistFound = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(diagnostics.renderedText().contains("download-domain policy"))
    }

    func testTraversesNestedIframeKeepsFrameRefererAndStopsCycle() async throws {
        let recorder = DiscoveryRequestRecorder()
        let resolver = makeResolver()
        DiscoveryURLProtocolStub.handler = { request in
            recorder.append(request)
            switch request.url?.path {
            case "/watch":
                return Self.response(
                    request,
                    body: #"<iframe src="/player/frame?token=abc"></iframe>"#,
                    mimeType: "text/html"
                )
            case "/player/frame":
                let html = #"""
                <iframe src="/watch"></iframe>
                <video poster="thumb.jpg"><source src="media/index.m3u8" type="application/x-mpegURL"></video>
                """#
                return Self.response(request, body: html, mimeType: "text/html")
            default:
                throw URLError(.fileDoesNotExist)
            }
        }

        let discovery = try await resolver.discover(input: "https://site.example/watch")
        XCTAssertEqual(discovery.candidates.count, 1)
        let candidate = try XCTUnwrap(discovery.candidates.first)
        XCTAssertEqual(
            candidate.playlistURL.absoluteString,
            "https://site.example/player/media/index.m3u8"
        )
        XCTAssertEqual(
            candidate.request.sameOriginQueryFallback?.absoluteString,
            "https://site.example/player/media/index.m3u8?token=abc"
        )
        XCTAssertEqual(candidate.requestReferer?.absoluteString, "https://site.example/player/frame?token=abc")
        XCTAssertEqual(candidate.thumbnailURL?.absoluteString, "https://site.example/player/thumb.jpg")
        XCTAssertEqual(candidate.iframeDepth, 1)

        let requests = recorder.snapshot()
        XCTAssertEqual(requests.count, 2, "rootへ戻るiframe cycleを再取得してはいけません")
        let frameRequest = try XCTUnwrap(requests.first { $0.url?.path == "/player/frame" })
        XCTAssertEqual(frameRequest.value(forHTTPHeaderField: "Referer"), "https://site.example/watch")
    }

    func testFindsSourceInsideIframeSrcdoc() async throws {
        let resolver = makeResolver()
        DiscoveryURLProtocolStub.handler = { request in
            let html = #"""
            <iframe title="埋め込み動画" srcdoc="&lt;video poster=&quot;/p.jpg&quot; src=&quot;/v.m3u8&quot;&gt;&lt;/video&gt;"></iframe>
            """#
            return Self.response(request, body: html, mimeType: "text/html")
        }

        let discovery = try await resolver.discover(input: "https://site.example/watch")
        let candidate = try XCTUnwrap(discovery.candidates.first)
        XCTAssertEqual(candidate.playlistURL.absoluteString, "https://site.example/v.m3u8")
        XCTAssertEqual(candidate.thumbnailURL?.absoluteString, "https://site.example/p.jpg")
        XCTAssertEqual(candidate.title, "埋め込み動画")
        XCTAssertEqual(candidate.iframeDepth, 1)
    }

    func testIframeSrcdocUsesParentDocumentBaseURL() async throws {
        let resolver = makeResolver()
        DiscoveryURLProtocolStub.handler = { request in
            let html = #"<base href="/assets/player/"><iframe srcdoc="&lt;video src=&quot;inside.m3u8&quot;&gt;&lt;/video&gt;"></iframe>"#
            return Self.response(request, body: html, mimeType: "text/html")
        }

        let discovery = try await resolver.discover(input: "https://site.example/watch")

        XCTAssertEqual(
            discovery.candidates.first?.playlistURL.absoluteString,
            "https://site.example/assets/player/inside.m3u8"
        )
    }

    @MainActor
    func testMergesDynamicPlayerCandidate() async throws {
        let dynamicURL = URL(string: "https://cdn.example/runtime/master.m3u8?token=abc")!
        let pageURL = URL(string: "https://player.example/embed/7")!
        let inspector = StubDynamicInspector(
            inspection: DynamicPageInspection(
                media: [
                    DynamicMediaReference(
                        url: dynamicURL,
                        kind: .hls,
                        pageURL: pageURL,
                        title: "Runtime player",
                        thumbnailURL: URL(string: "https://player.example/poster.jpg"),
                        iframeDepth: 1,
                        origin: .runtime
                    )
                ],
                cookies: []
            )
        )
        let resolver = makeResolver(dynamicInspector: inspector)
        DiscoveryURLProtocolStub.handler = { request in
            Self.response(request, body: "<div id='player'></div>", mimeType: "text/html")
        }

        let discovery = try await resolver.discover(input: "https://site.example/watch")
        XCTAssertEqual(discovery.candidates.count, 1)
        let candidate = try XCTUnwrap(discovery.candidates.first)
        XCTAssertEqual(candidate.playlistURL, dynamicURL)
        XCTAssertEqual(candidate.requestReferer, pageURL)
        XCTAssertEqual(candidate.title, "Runtime player")
        XCTAssertEqual(candidate.origin, .runtime)
    }

    func testInteractiveInspectionValidatesAllowedWidevineAndRejectsOtherDomains() async throws {
        let recorder = DiscoveryRequestRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryURLProtocolStub.self]
        let client = HTTPClient(configuration: configuration)
        let diagnostics = DiagnosticLogStore()
        let resolver = SourceResolver(client: client, diagnosticSink: diagnostics.sink)
        let rootURL = URL(string: "https://site.example/watch")!
        let allowedURL = URL(string: "https://widevine.sprink.cloud/video/manifest.mpd")!
        let deniedURL = URL(string: "https://example.com/video/manifest.mpd")!
        DiscoveryURLProtocolStub.handler = { request in
            recorder.append(request)
            return Self.response(request, body: Self.widevineMPD, mimeType: "application/dash+xml")
        }
        let inspection = DynamicPageInspection(
            media: [
                DynamicMediaReference(
                    url: deniedURL,
                    kind: .widevineDASH,
                    pageURL: rootURL,
                    title: nil,
                    thumbnailURL: nil,
                    iframeDepth: 1,
                    origin: .runtime
                ),
                DynamicMediaReference(
                    url: allowedURL,
                    kind: .widevineDASH,
                    pageURL: rootURL,
                    title: "Widevine player",
                    thumbnailURL: nil,
                    iframeDepth: 1,
                    origin: .runtime
                )
            ],
            cookies: []
        )

        let candidates = await resolver.importDynamicInspection(inspection, rootURL: rootURL)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.kind, .widevineDASH)
        XCTAssertEqual(candidates.first?.playlistURL, allowedURL)
        XCTAssertNotNil(candidates.first?.document)
        XCTAssertEqual(recorder.snapshot().compactMap(\.url), [deniedURL, allowedURL])
        XCTAssertTrue(diagnostics.renderedText().contains("download-domain policy"))
    }

    func testInteractiveInspectionAssociatesLicenseRequestsByFrameTokenAndSequence() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryURLProtocolStub.self]
        let client = HTTPClient(configuration: configuration)
        let diagnostics = DiagnosticLogStore()
        let resolver = SourceResolver(client: client, diagnosticSink: diagnostics.sink)
        let rootURL = try XCTUnwrap(URL(string: "https://site.example/watch"))
        let sharedPageURL = try XCTUnwrap(URL(string: "https://player.example/embed"))
        let firstMPD = try XCTUnwrap(
            URL(string: "https://widevine.sprink.cloud/video/first.mpd")
        )
        let secondMPD = try XCTUnwrap(
            URL(string: "https://widevine.sprink.cloud/video/second.mpd")
        )
        let firstLicense = try XCTUnwrap(
            URL(string: "https://license.example/acquire?token=first-secret")
        )
        let secondLicense = try XCTUnwrap(
            URL(string: "https://license.example/acquire?token=second-secret")
        )
        DiscoveryURLProtocolStub.handler = { request in
            Self.response(request, body: Self.widevineMPD, mimeType: "application/dash+xml")
        }
        let metadata = WidevineLicenseRequestMetadata(
            method: " post ",
            contentType: "Application/OCTET-STREAM; charset=binary",
            headerNames: ["Authorization", "X-Playback-Token", "authorization"],
            bodyKind: .binary,
            bodyByteCount: 512,
            source: .emeCorrelatedFetch
        )
        let inspection = DynamicPageInspection(
            media: [
                DynamicMediaReference(
                    url: firstMPD,
                    kind: .widevineDASH,
                    pageURL: sharedPageURL,
                    title: "First",
                    thumbnailURL: nil,
                    iframeDepth: 1,
                    origin: .runtime,
                    frameToken: "frame-first",
                    sequence: 10
                ),
                DynamicMediaReference(
                    url: secondMPD,
                    kind: .widevineDASH,
                    pageURL: sharedPageURL,
                    title: "Second",
                    thumbnailURL: nil,
                    iframeDepth: 1,
                    origin: .runtime,
                    frameToken: "frame-second",
                    sequence: 20
                )
            ],
            cookies: [],
            licenseRequests: [
                DynamicLicenseReference(
                    url: secondLicense,
                    pageURL: sharedPageURL,
                    iframeDepth: 1,
                    frameToken: "frame-second",
                    metadata: metadata,
                    sequence: 22
                ),
                DynamicLicenseReference(
                    url: firstLicense,
                    pageURL: sharedPageURL,
                    iframeDepth: 1,
                    frameToken: "frame-first",
                    metadata: metadata,
                    sequence: 12
                )
            ],
            detectedWidevineKeySystem: true
        )

        let candidates = await resolver.importDynamicInspection(inspection, rootURL: rootURL)
        let byManifest = Dictionary(uniqueKeysWithValues: candidates.map { ($0.playlistURL, $0) })
        let firstContext = try XCTUnwrap(byManifest[firstMPD]?.widevinePlaybackContext)
        let secondContext = try XCTUnwrap(byManifest[secondMPD]?.widevinePlaybackContext)

        XCTAssertEqual(firstContext.licenseServerURL, firstLicense)
        XCTAssertEqual(secondContext.licenseServerURL, secondLicense)
        XCTAssertEqual(firstContext.requestMetadata.method, "POST")
        XCTAssertEqual(firstContext.requestMetadata.contentType, "application/octet-stream")
        XCTAssertEqual(
            firstContext.requestMetadata.headerNames,
            ["authorization", "x-playback-token"]
        )
        XCTAssertTrue(firstContext.detectedWidevineKeySystem)
        XCTAssertTrue(firstContext.isHighConfidence)
        XCTAssertFalse(firstContext.isReplayable)
        let log = diagnostics.renderedText()
        XCTAssertTrue(log.contains("licenseRequests=2 matched=2 eme=true"))
        XCTAssertFalse(log.contains("first-secret"))
        XCTAssertFalse(log.contains("second-secret"))
        XCTAssertFalse(log.contains("license.example"))
    }

    func testInteractiveInspectionDoesNotGuessLicenseForAmbiguousSameFrameManifests() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryURLProtocolStub.self]
        let client = HTTPClient(configuration: configuration)
        let resolver = SourceResolver(client: client)
        let rootURL = try XCTUnwrap(URL(string: "https://site.example/watch"))
        let pageURL = try XCTUnwrap(URL(string: "https://player.example/embed"))
        let firstMPD = try XCTUnwrap(
            URL(string: "https://widevine.sprink.cloud/video/first.mpd")
        )
        let secondMPD = try XCTUnwrap(
            URL(string: "https://widevine.sprink.cloud/video/second.mpd")
        )
        DiscoveryURLProtocolStub.handler = { request in
            Self.response(request, body: Self.widevineMPD, mimeType: "application/dash+xml")
        }
        let inspection = DynamicPageInspection(
            media: [
                DynamicMediaReference(
                    url: firstMPD,
                    kind: .widevineDASH,
                    pageURL: pageURL,
                    title: nil,
                    thumbnailURL: nil,
                    iframeDepth: 1,
                    origin: .runtime,
                    frameToken: nil,
                    sequence: 10
                ),
                DynamicMediaReference(
                    url: secondMPD,
                    kind: .widevineDASH,
                    pageURL: pageURL,
                    title: nil,
                    thumbnailURL: nil,
                    iframeDepth: 1,
                    origin: .runtime,
                    frameToken: nil,
                    sequence: 10
                )
            ],
            cookies: [],
            licenseRequests: [
                DynamicLicenseReference(
                    url: try XCTUnwrap(URL(string: "https://license.example/acquire")),
                    pageURL: pageURL,
                    iframeDepth: 1,
                    metadata: WidevineLicenseRequestMetadata(
                        method: "POST",
                        contentType: nil,
                        headerNames: [],
                        bodyKind: .binary,
                        bodyByteCount: 128,
                        source: .fetch
                    ),
                    sequence: 12
                )
            ],
            detectedWidevineKeySystem: true
        )

        let candidates = await resolver.importDynamicInspection(inspection, rootURL: rootURL)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.allSatisfy { $0.widevinePlaybackContext == nil })
    }

    func testInteractiveInspectionRejectsSingleWidevineLicenseAcrossDifferentFrames() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryURLProtocolStub.self]
        let client = HTTPClient(configuration: configuration)
        let resolver = SourceResolver(client: client)
        let rootURL = try XCTUnwrap(URL(string: "https://site.example/watch"))
        let manifestURL = try XCTUnwrap(
            URL(string: "https://widevine.sprink.cloud/video/manifest.mpd")
        )
        let licenseURL = try XCTUnwrap(URL(string: "https://license.example/acquire"))
        DiscoveryURLProtocolStub.handler = { request in
            Self.response(request, body: Self.widevineMPD, mimeType: "application/dash+xml")
        }
        let inspection = DynamicPageInspection(
            media: [
                DynamicMediaReference(
                    url: manifestURL,
                    kind: .widevineDASH,
                    pageURL: try XCTUnwrap(URL(string: "https://player.example/manifest-frame")),
                    title: nil,
                    thumbnailURL: nil,
                    iframeDepth: 1,
                    origin: .runtime,
                    frameToken: "manifest-frame",
                    sequence: 10
                )
            ],
            cookies: [],
            licenseRequests: [
                DynamicLicenseReference(
                    url: licenseURL,
                    pageURL: try XCTUnwrap(URL(string: "https://player.example/license-frame")),
                    iframeDepth: 2,
                    frameToken: "license-frame",
                    metadata: WidevineLicenseRequestMetadata(
                        method: "POST",
                        contentType: "application/json",
                        headerNames: ["content-type"],
                        bodyKind: .json,
                        bodyByteCount: 256,
                        source: .emeCorrelatedXMLHttpRequest
                    ),
                    sequence: 12
                )
            ],
            detectedWidevineKeySystem: true
        )

        let candidates = await resolver.importDynamicInspection(inspection, rootURL: rootURL)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertNil(candidates.first?.widevinePlaybackContext)
    }

    @MainActor
    func testUsesDynamicInspectionWhenInitialNativeRequestIsRejected() async throws {
        let dynamicURL = URL(string: "https://cdn.example/runtime/master.m3u8")!
        let pageURL = URL(string: "https://player.example/embed/7")!
        let inspector = StubDynamicInspector(
            inspection: DynamicPageInspection(
                media: [
                    DynamicMediaReference(
                        url: dynamicURL,
                        kind: .hls,
                        pageURL: pageURL,
                        title: nil,
                        thumbnailURL: nil,
                        iframeDepth: 1,
                        origin: .runtime
                    )
                ],
                cookies: []
            )
        )
        let resolver = makeResolver(dynamicInspector: inspector)
        DiscoveryURLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html"]
            )!
            return (response, Data("blocked".utf8))
        }

        let discovery = try await resolver.discover(input: "https://site.example/watch")

        XCTAssertEqual(discovery.candidates.first?.playlistURL, dynamicURL)
        XCTAssertEqual(discovery.candidates.first?.requestReferer, pageURL)
    }

    func testInteractiveInspectionImportsCookiesAndBlocksPrivateTargetsFromPublicPage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryURLProtocolStub.self]
        let client = HTTPClient(configuration: configuration)
        let resolver = SourceResolver(client: client)
        let rootURL = try XCTUnwrap(URL(string: "https://site.example/watch"))
        let publicManifest = try XCTUnwrap(
            URL(string: "https://cdn.example/runtime/master.m3u8?token=secret")
        )
        let privateManifest = try XCTUnwrap(
            URL(string: "http://127.0.0.1:8080/private/master.m3u8")
        )
        let cookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "playback",
                .value: "private-value",
                .domain: "cdn.example",
                .path: "/"
            ])
        )
        let inspection = DynamicPageInspection(
            media: [
                DynamicMediaReference(
                    url: privateManifest,
                    kind: .hls,
                    pageURL: rootURL,
                    title: nil,
                    thumbnailURL: nil,
                    iframeDepth: 1,
                    origin: .runtime
                ),
                DynamicMediaReference(
                    url: publicManifest,
                    kind: .hls,
                    pageURL: rootURL,
                    title: "Playback candidate",
                    thumbnailURL: nil,
                    iframeDepth: 1,
                    origin: .runtime
                )
            ],
            cookies: [cookie]
        )

        let candidates = await resolver.importDynamicInspection(inspection, rootURL: rootURL)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.playlistURL, publicManifest)
        XCTAssertEqual(candidates.first?.requestReferer, rootURL)
        XCTAssertEqual(client.cookies(for: publicManifest).map(\.name), ["playback"])
    }

    func testDoesNotAutomaticallyFetchPrivateIframeFromPublicPage() async throws {
        let recorder = DiscoveryRequestRecorder()
        let resolver = makeResolver()
        DiscoveryURLProtocolStub.handler = { request in
            recorder.append(request)
            return Self.response(
                request,
                body: #"<iframe src="http://127.0.0.1:8080/player"></iframe><video src="/safe.m3u8"></video>"#,
                mimeType: "text/html"
            )
        }

        let discovery = try await resolver.discover(input: "https://public.example/watch")
        XCTAssertEqual(discovery.candidates.count, 1)
        XCTAssertEqual(recorder.snapshot().count, 1)
    }

    func testDiscoveryDiagnosticsExplainCoverageWithoutLeakingURLSecrets() async throws {
        let diagnostics = DiagnosticLogStore()
        let resolver = makeResolver(diagnostics: diagnostics)
        DiscoveryURLProtocolStub.handler = { request in
            Self.response(
                request,
                body: #"<iframe src="http://127.0.0.1/player"></iframe><video src="/master.m3u8?token=top-secret"></video>"#,
                mimeType: "text/html"
            )
        }

        let discovery = try await resolver.discover(input: "https://site.example/watch?session=private")
        XCTAssertEqual(discovery.candidates.count, 1)

        let text = diagnostics.renderedText()
        XCTAssertTrue(text.contains("document depth=0 media=1 frames=1"))
        XCTAssertTrue(text.contains("automatic fetch blocked"))
        XCTAssertTrue(text.contains("added origin=video"))
        XCTAssertFalse(text.contains("top-secret"))
        XCTAssertFalse(text.contains("session=private"))
        XCTAssertFalse(text.contains("site.example"))
    }

    func testAutomaticNavigationBlocksAdditionalLocalAddressForms() throws {
        let publicURL = URL(string: "https://public.example/watch")!
        let blocked = [
            "http://2130706433/player",
            "http://127.1/player",
            "http://[::ffff:127.0.0.1]/player",
            "http://[::ffff:7f00:1]/player",
            "http://device.internal/player",
            "http://device.lan/player"
        ].compactMap(URL.init(string:))

        XCTAssertEqual(blocked.count, 6)
        for target in blocked {
            XCTAssertFalse(
                AutomaticNavigationPolicy.isAllowedFrameNavigation(from: publicURL, to: target),
                target.absoluteString
            )
        }
    }

    func testNativeIframeCrawlerDoesNotCrossOriginsFromPublicPage() throws {
        let root = URL(string: "https://site.example/watch")!
        let sameOrigin = URL(string: "https://site.example/player")!
        let crossOrigin = URL(string: "https://embed.example/player")!

        XCTAssertTrue(
            AutomaticNavigationPolicy.isAllowedNativeFrameNavigation(from: root, to: sameOrigin)
        )
        XCTAssertFalse(
            AutomaticNavigationPolicy.isAllowedNativeFrameNavigation(from: root, to: crossOrigin)
        )
        XCTAssertTrue(
            AutomaticNavigationPolicy.isAllowedFrameNavigation(from: root, to: crossOrigin),
            "WebKitはブラウザ境界内で公開cross-origin iframeを読み込めます"
        )
    }

    func testImportedHostOnlyCookieIsNotSentToSubdomain() async throws {
        let recorder = DiscoveryRequestRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryURLProtocolStub.self]
        let client = HTTPClient(configuration: configuration)
        let cookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "session",
                .value: "secret",
                .domain: "example.com",
                .path: "/"
            ])
        )
        client.storeCookies([cookie])
        DiscoveryURLProtocolStub.handler = { request in
            recorder.append(request)
            return Self.response(request, body: "ok", mimeType: "text/plain")
        }

        _ = try await client.fetch(URL(string: "https://example.com/root")!)
        _ = try await client.fetch(URL(string: "https://sub.example.com/child")!)

        let requests = recorder.snapshot()
        XCTAssertEqual(
            requests.first(where: { $0.url?.host == "example.com" })?
                .value(forHTTPHeaderField: "Cookie"),
            "session=secret"
        )
        XCTAssertNil(
            requests.first(where: { $0.url?.host == "sub.example.com" })?
                .value(forHTTPHeaderField: "Cookie")
        )
    }

    func testImportedCookieGateUsesSchemefulRefererContext() async throws {
        let recorder = DiscoveryRequestRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryURLProtocolStub.self]
        let client = HTTPClient(configuration: configuration)
        let hostOnly = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "hostOnly",
                .value: "exact",
                .domain: "cdn.example.com",
                .path: "/"
            ])
        )
        let domain = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "domain",
                .value: "shared",
                .domain: ".example.com",
                .path: "/"
            ])
        )
        client.storeCookies([hostOnly, domain])
        DiscoveryURLProtocolStub.handler = { request in
            recorder.append(request)
            return Self.response(request, body: "ok", mimeType: "text/plain")
        }

        let target = try XCTUnwrap(URL(string: "https://cdn.example.com/media/master.m3u8"))
        _ = try await client.fetch(
            target,
            referer: URL(string: "https://page.example.com/watch")
        )
        _ = try await client.fetch(
            target,
            referer: URL(string: "https://cdn.example.com/watch")
        )
        _ = try await client.fetch(
            target,
            referer: URL(string: "https://page.example.com.evil/watch")
        )
        _ = try await client.fetch(
            target,
            referer: URL(string: "http://page.example.com/watch")
        )

        let requests = recorder.snapshot()
        XCTAssertEqual(requests.count, 4)
        let siblingHeader = requests[0].value(forHTTPHeaderField: "Cookie")
        XCTAssertEqual(siblingHeader, "domain=shared")
        let exactHeader = try XCTUnwrap(requests[1].value(forHTTPHeaderField: "Cookie"))
        XCTAssertTrue(exactHeader.contains("hostOnly=exact"))
        XCTAssertTrue(exactHeader.contains("domain=shared"))
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(requests[3].value(forHTTPHeaderField: "Cookie"))
    }

    func testIsolatedDownloadCookieJarKeepsDiscoveryAndJobCookiesWithoutCrossJobLeak() async throws {
        let recorder = DiscoveryRequestRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryURLProtocolStub.self]
        let analysisClient = HTTPClient(configuration: configuration)
        let browserCookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "browser",
                .value: "persistent",
                .domain: "media.example.com",
                .path: "/",
                .secure: "TRUE"
            ])
        )
        analysisClient.storeCookies([browserCookie])
        let pageURL = try XCTUnwrap(URL(string: "https://media.example.com/watch"))
        let manifestURL = try XCTUnwrap(
            URL(string: "https://media.example.com/video/master.m3u8")
        )
        let segmentURL = try XCTUnwrap(
            URL(string: "https://media.example.com/segments/0001.ts")
        )
        DiscoveryURLProtocolStub.handler = { request in
            recorder.append(request)
            let headers: [String: String]
            switch request.url?.path {
            case "/watch":
                headers = [
                    "Content-Type": "text/html",
                    "Set-Cookie": "discovery=one; Path=/; Secure; HttpOnly"
                ]
            case "/video/master.m3u8":
                headers = [
                    "Content-Type": "application/vnd.apple.mpegurl",
                    "Set-Cookie": "download=one; Path=/segments; Secure; HttpOnly"
                ]
            default:
                headers = ["Content-Type": "video/mp2t"]
            }
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )
            )
            return (response, Data("ok".utf8))
        }

        _ = try await analysisClient.fetch(pageURL)
        let firstJob = analysisClient.makeIsolatedDownloadClient(
            scopedTo: [pageURL, manifestURL]
        )
        _ = try await firstJob.fetch(manifestURL, referer: pageURL)
        _ = try await firstJob.fetch(segmentURL, referer: manifestURL)

        let firstRequests = recorder.snapshot()
        let manifestCookies = try XCTUnwrap(
            firstRequests.first { $0.url == manifestURL }?
                .value(forHTTPHeaderField: "Cookie")
        )
        XCTAssertTrue(manifestCookies.contains("browser=persistent"))
        XCTAssertTrue(manifestCookies.contains("discovery=one"))
        let segmentCookies = try XCTUnwrap(
            firstRequests.first { $0.url == segmentURL }?
                .value(forHTTPHeaderField: "Cookie")
        )
        XCTAssertTrue(segmentCookies.contains("browser=persistent"))
        XCTAssertTrue(segmentCookies.contains("discovery=one"))
        XCTAssertTrue(segmentCookies.contains("download=one"))

        analysisClient.resetTransientResponseCookies()
        let secondJob = analysisClient.makeIsolatedDownloadClient(
            scopedTo: [pageURL, manifestURL]
        )
        _ = try await secondJob.fetch(segmentURL, referer: manifestURL)
        let secondJobCookies = try XCTUnwrap(
            recorder.snapshot().last?.value(forHTTPHeaderField: "Cookie")
        )
        XCTAssertTrue(secondJobCookies.contains("browser=persistent"))
        XCTAssertFalse(secondJobCookies.contains("discovery=one"))
        XCTAssertFalse(secondJobCookies.contains("download=one"))
    }

    func testPersistentCookieSnapshotPreservesScopeAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func makeCookie(
            name: String,
            domain: String,
            path: String,
            secure: Bool = false,
            expires: Date? = nil
        ) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: "secret",
                .domain: domain,
                .path: path
            ]
            if secure { properties[.secure] = "TRUE" }
            if let expires { properties[.expires] = expires }
            return try XCTUnwrap(HTTPCookie(properties: properties))
        }

        let cookies = try [
            makeCookie(
                name: "valid",
                domain: "media.example.com",
                path: "/video",
                secure: true,
                expires: now.addingTimeInterval(60)
            ),
            makeCookie(name: "domain", domain: ".example.com", path: "/video"),
            makeCookie(name: "hostOnlyParent", domain: "example.com", path: "/video"),
            makeCookie(name: "lookalike", domain: ".example.com.evil", path: "/video"),
            makeCookie(name: "wrongPath", domain: "media.example.com", path: "/account"),
            makeCookie(name: "pathBoundary", domain: "media.example.com", path: "/vid"),
            makeCookie(
                name: "expired",
                domain: "media.example.com",
                path: "/video",
                expires: now.addingTimeInterval(-1)
            ),
            makeCookie(name: "unobserved", domain: "unrelated.example", path: "/")
        ]
        let httpsURL = try XCTUnwrap(
            URL(string: "https://media.example.com/video/master.m3u8")
        )
        let httpURL = try XCTUnwrap(
            URL(string: "http://media.example.com/video/master.m3u8")
        )

        let httpsSnapshot = HTTPClient.snapshotCookies(
            cookies,
            matching: [httpsURL],
            now: now
        )
        XCTAssertEqual(
            Set(httpsSnapshot.map(\.name)),
            Set(["valid", "domain", "wrongPath", "pathBoundary"])
        )
        let retained = try XCTUnwrap(httpsSnapshot.first { $0.name == "valid" })
        XCTAssertEqual(retained.domain, "media.example.com")
        XCTAssertEqual(retained.path, "/video")
        XCTAssertTrue(retained.isSecure)
        XCTAssertEqual(retained.expiresDate, now.addingTimeInterval(60))

        let httpSnapshot = HTTPClient.snapshotCookies(
            cookies,
            matching: [httpURL],
            now: now
        )
        XCTAssertEqual(
            Set(httpSnapshot.map(\.name)),
            Set(["domain", "wrongPath", "pathBoundary"])
        )
    }

    func testSnapshotRetainsSegmentPathButRequestGateEnforcesIt() async throws {
        let manifestURL = try XCTUnwrap(
            URL(string: "https://media.example.com/video/master.m3u8")
        )
        let segmentCookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "segment",
                .value: "secret",
                .domain: "media.example.com",
                .path: "/segments",
                .secure: "TRUE"
            ])
        )
        let snapshot = HTTPClient.snapshotCookies(
            [segmentCookie],
            matching: [manifestURL]
        )
        XCTAssertEqual(snapshot.map(\.name), ["segment"])
        XCTAssertEqual(snapshot.first?.path, "/segments")

        let recorder = DiscoveryRequestRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryURLProtocolStub.self]
        let client = HTTPClient(configuration: configuration)
        client.storeCookies(snapshot)
        DiscoveryURLProtocolStub.handler = { request in
            recorder.append(request)
            return Self.response(request, body: "ok", mimeType: "text/plain")
        }

        _ = try await client.fetch(
            URL(string: "https://media.example.com/segments/0001.ts")!,
            referer: manifestURL
        )
        _ = try await client.fetch(
            URL(string: "https://media.example.com/other/0001.ts")!,
            referer: manifestURL
        )

        let requests = recorder.snapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Cookie"), "segment=secret")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie"))
    }

    func testRedirectDelegateRejectsPublicToPrivateBeforeFollowing() throws {
        let sourceURL = URL(string: "https://public.example/frame")!
        let privateURL = URL(string: "http://127.0.0.1/player")!
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: sourceURL)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: sourceURL,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": privateURL.absoluteString]
            )
        )
        var receivedDecision = false
        var redirectedRequest: URLRequest?

        HTTPRedirectDelegate().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: privateURL)
        ) {
            receivedDecision = true
            redirectedRequest = $0
        }

        XCTAssertTrue(receivedDecision)
        XCTAssertNil(redirectedRequest)
    }

    func testRedirectDelegateRebuildsCookieForTargetPath() throws {
        let sourceURL = try XCTUnwrap(
            URL(string: "https://media.example.com/segments/0001.ts")
        )
        let targetURL = try XCTUnwrap(
            URL(string: "https://media.example.com/other/0001.ts")
        )
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let manifestContext = try XCTUnwrap(
            URL(string: "https://media.example.com/video/master.m3u8")
        )
        var originalRequest = URLRequest(url: sourceURL)
        originalRequest.setValue(
            manifestContext.absoluteString,
            forHTTPHeaderField: "Referer"
        )
        let task = session.dataTask(with: originalRequest)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: sourceURL,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": targetURL.absoluteString]
            )
        )
        var proposed = URLRequest(url: targetURL)
        proposed.setValue("segment=secret", forHTTPHeaderField: "Cookie")
        proposed.setValue(
            "https://media.example.com/video/master.m3u8",
            forHTTPHeaderField: "Referer"
        )
        let delegate = HTTPRedirectDelegate()
        var providerTarget: URL?
        var providerContext: URL?
        delegate.cookieHeaderProvider = { target, context in
            providerTarget = target
            providerContext = context
            return nil
        }
        var redirectedRequest: URLRequest?

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: proposed
        ) {
            redirectedRequest = $0
        }

        XCTAssertEqual(providerTarget, targetURL)
        XCTAssertEqual(providerContext, manifestContext)
        XCTAssertNil(redirectedRequest?.value(forHTTPHeaderField: "Cookie"))
    }

    func testRedirectDelegateKeepsOriginalCrossSiteCookieContext() throws {
        let originalURL = try XCTUnwrap(URL(string: "https://a.example.com/start"))
        let originalContext = try XCTUnwrap(URL(string: "https://outside.invalid/watch"))
        let targetURL = try XCTUnwrap(URL(string: "https://b.example.com/media"))
        var originalRequest = URLRequest(url: originalURL)
        originalRequest.setValue(originalContext.absoluteString, forHTTPHeaderField: "Referer")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: originalRequest)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: originalURL,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": targetURL.absoluteString]
            )
        )
        var proposed = URLRequest(url: targetURL)
        proposed.setValue("domain=secret", forHTTPHeaderField: "Cookie")
        let delegate = HTTPRedirectDelegate()
        var providerContext: URL?
        delegate.cookieHeaderProvider = { _, context in
            providerContext = context
            return nil
        }
        var redirectedRequest: URLRequest?

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: proposed
        ) {
            redirectedRequest = $0
        }

        XCTAssertEqual(providerContext, originalContext)
        XCTAssertNil(redirectedRequest?.value(forHTTPHeaderField: "Cookie"))
    }

    private static let widevineMPD = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
      <Period>
        <AdaptationSet contentType="video">
          <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/>
          <Representation id="v1"/>
        </AdaptationSet>
      </Period>
    </MPD>
    """#

    private func makeResolver(
        dynamicInspector: (any DynamicPageInspecting)? = nil,
        diagnostics: DiagnosticLogStore? = nil
    ) -> SourceResolver {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryURLProtocolStub.self]
        return SourceResolver(
            client: HTTPClient(configuration: configuration),
            dynamicInspector: dynamicInspector,
            diagnosticSink: diagnostics?.sink
        )
    }

    private static func response(
        _ request: URLRequest,
        body: String,
        mimeType: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mimeType]
        )!
        return (response, Data(body.utf8))
    }
}
