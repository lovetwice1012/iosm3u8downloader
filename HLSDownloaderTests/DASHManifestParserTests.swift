import XCTest
@testable import HLSDownloader

final class DASHManifestParserTests: XCTestCase {
    private let manifestURL = URL(string: "https://widevine.sprink.cloud/video/manifest.mpd")!
    private let emptyWidevinePSSH = "AAAAIHBzc2gAAAAA7e+LqXnWSs6jyCfc1R0h7QAAAAA="
    private let widevinePSSHV1 = "AAAAN3Bzc2gBAAAA7e+LqXnWSs6jyCfc1R0h7QAAAAERERERIiIzM0REVVVVVVVVAAAAAwECAw=="

    func testParsesWidevineCENCCBCSTracksAndSegments() throws {
        let xml = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
             xmlns:cenc="urn:mpeg:cenc:2013"
             xmlns:dashif="https://dashif.org/CPS"
             type="static"
             mediaPresentationDuration="PT12S">
          <BaseURL>media/</BaseURL>
          <Period id="p0" start="PT0S" duration="PT12S">
            <AdaptationSet id="video" contentType="video" mimeType="video/mp4">
              <ContentProtection
                  schemeIdUri="urn:mpeg:dash:mp4protection:2011"
                  value="cenc:00010000"
                  cenc:default_KID="11111111-2222-3333-4444-555555555555" />
              <ContentProtection
                  schemeIdUri="URN:UUID:EDEF8BA9-79D6-4ACE-A3C8-27DCD51D21ED">
                <cenc:pssh><![CDATA[\#(emptyWidevinePSSH)]]></cenc:pssh>
                <dashif:Laurl licenseType="EME-1.0">../license/widevine</dashif:Laurl>
              </ContentProtection>
              <SegmentTemplate
                  timescale="1000"
                  initialization="video/$RepresentationID$/init.mp4"
                  media="video/$RepresentationID$/$Number$.m4s"
                  startNumber="1">
                <SegmentTimeline>
                  <S t="0" d="4000" r="2" />
                </SegmentTimeline>
              </SegmentTemplate>
              <Representation id="v1" bandwidth="2500000" codecs="avc1.640028" width="1920" height="1080">
                <BaseURL>main/</BaseURL>
              </Representation>
            </AdaptationSet>
            <AdaptationSet id="audio" mimeType="audio/mp4" lang="ja">
              <ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011" value="cbcs" />
              <Representation id="a1" bandwidth="128000" codecs="mp4a.40.2">
                <SegmentList timescale="48000" duration="192000" startNumber="7">
                  <Initialization sourceURL="audio/init.mp4" range="0-899" />
                  <SegmentURL media="audio/7.m4s" mediaRange="900-1999" />
                  <SegmentURL media="audio/8.m4s" />
                </SegmentList>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """#

        XCTAssertTrue(DASHManifestParser.isMPD(xml))
        let manifest = try DASHManifestParser.parse(text: xml, effectiveURL: manifestURL)

        XCTAssertEqual(manifest.presentationType, .staticPresentation)
        XCTAssertEqual(manifest.mediaPresentationDuration, "PT12S")
        XCTAssertTrue(manifest.isWidevine)
        XCTAssertEqual(manifest.encryptionSchemes, [.cenc, .cbcs])
        XCTAssertEqual(manifest.periods.map(\.id), ["p0"])
        XCTAssertEqual(manifest.adaptationSets.map(\.mediaType), [.video, .audio])
        XCTAssertEqual(manifest.baseURLs.first?.rawValue, "media/")
        XCTAssertEqual(
            manifest.baseURLs.first?.resolvedURL?.absoluteString,
            "https://widevine.sprink.cloud/video/media/"
        )

        let protection = try XCTUnwrap(manifest.allContentProtections.first(where: { $0.isWidevine }))
        let pssh = try XCTUnwrap(protection.psshBoxes.first)
        XCTAssertEqual(pssh.version, 0)
        XCTAssertEqual(pssh.flags, 0)
        XCTAssertEqual(pssh.systemID, DASHManifestParser.widevineSystemID)
        XCTAssertEqual(pssh.keyIDs, [])
        XCTAssertEqual(pssh.data, Data())
        XCTAssertEqual(
            protection.licenseURLs.map(\.absoluteString),
            ["https://widevine.sprink.cloud/license/widevine"]
        )

        let cencProtection = try XCTUnwrap(
            manifest.allContentProtections.first(where: { $0.commonEncryptionScheme == .cenc })
        )
        XCTAssertEqual(cencProtection.defaultKeyIDs, ["11111111-2222-3333-4444-555555555555"])

        let video = try XCTUnwrap(manifest.adaptationSets.first(where: { $0.mediaType == .video }))
        let template = try XCTUnwrap(video.segmentTemplate)
        XCTAssertEqual(template.initialization, "video/$RepresentationID$/init.mp4")
        XCTAssertEqual(template.media, "video/$RepresentationID$/$Number$.m4s")
        XCTAssertEqual(template.timescale, 1000)
        XCTAssertEqual(template.startNumber, 1)
        XCTAssertEqual(template.timeline, [DASHSegmentTimelineEntry(startTime: 0, duration: 4000, repeatCount: 2)])
        let videoRepresentation = try XCTUnwrap(video.representations.first)
        XCTAssertEqual(videoRepresentation.mediaType, .video)
        XCTAssertEqual(videoRepresentation.bandwidth, 2_500_000)
        XCTAssertEqual(videoRepresentation.width, 1920)
        XCTAssertEqual(videoRepresentation.height, 1080)
        XCTAssertEqual(videoRepresentation.baseURLs.first?.rawValue, "main/")
        XCTAssertEqual(
            videoRepresentation.baseURLs.first?.resolvedURL?.absoluteString,
            "https://widevine.sprink.cloud/video/media/main/"
        )

        let audio = try XCTUnwrap(manifest.adaptationSets.first(where: { $0.mediaType == .audio }))
        XCTAssertEqual(audio.language, "ja")
        let list = try XCTUnwrap(audio.representations.first?.segmentList)
        XCTAssertEqual(list.timescale, 48_000)
        XCTAssertEqual(list.duration, 192_000)
        XCTAssertEqual(list.startNumber, 7)
        XCTAssertEqual(list.initializationSourceURL, "audio/init.mp4")
        XCTAssertEqual(list.initializationRange, "0-899")
        XCTAssertEqual(list.segmentURLs.count, 2)
        XCTAssertEqual(list.segmentURLs.first?.mediaRange, "900-1999")
    }

    func testDetectsWidevineFromValidatedPSSHWithoutTrustingLabels() throws {
        let xml = #"""
        <MPD xmlns:cenc="urn:mpeg:cenc:2013">
          <Period><AdaptationSet contentType="video">
            <ContentProtection schemeIdUri="urn:example:not-widevine" value="Widevine">
              <cenc:pssh>\#(emptyWidevinePSSH)</cenc:pssh>
            </ContentProtection>
          </AdaptationSet></Period>
        </MPD>
        """#

        let manifest = try DASHManifestParser.parse(text: xml, effectiveURL: manifestURL)
        XCTAssertTrue(manifest.isWidevine)
        XCTAssertEqual(manifest.psshBoxes.map(\.systemID), [DASHManifestParser.widevineSystemID])
    }

    func testParsesVersionOnePSSHKeyIDsAndPayload() throws {
        let xml = #"""
        <MPD xmlns:cenc="urn:mpeg:cenc:2013">
          <Period><AdaptationSet><ContentProtection>
            <cenc:pssh>\#(widevinePSSHV1)</cenc:pssh>
          </ContentProtection></AdaptationSet></Period>
        </MPD>
        """#

        let manifest = try DASHManifestParser.parse(text: xml, effectiveURL: manifestURL)
        let pssh = try XCTUnwrap(manifest.psshBoxes.first)
        XCTAssertEqual(pssh.version, 1)
        XCTAssertEqual(pssh.keyIDs, ["11111111-2222-3333-4444-555555555555"])
        XCTAssertEqual(pssh.data, Data([0x01, 0x02, 0x03]))
        XCTAssertTrue(manifest.isWidevine)
    }

    func testParsesDynamicPresentationAndInfersAdaptationTypeFromRepresentation() throws {
        let xml = """
        <MPD xmlns="\(DASHManifestParser.namespace)" type="dynamic" minimumUpdatePeriod="PT5S">
          <Period><AdaptationSet><Representation id="v" mimeType="video/mp4" /></AdaptationSet></Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(text: xml, effectiveURL: manifestURL)
        XCTAssertEqual(manifest.presentationType, .dynamic)
        XCTAssertEqual(manifest.minimumUpdatePeriod, "PT5S")
        XCTAssertEqual(manifest.adaptationSets.first?.mediaType, .video)
        XCTAssertEqual(manifest.adaptationSets.first?.representations.first?.mediaType, .video)
    }

    func testRejectsSpoofedWidevineURIAndMalformedPSSH() throws {
        let xml = #"""
        <MPD xmlns:cenc="urn:mpeg:cenc:2013">
          <Period><AdaptationSet contentType="video">
            <ContentProtection
                schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed.example">
              <cenc:pssh>bm90LWEtcHNzaC1ib3g=</cenc:pssh>
            </ContentProtection>
          </AdaptationSet></Period>
        </MPD>
        """#

        let manifest = try DASHManifestParser.parse(text: xml, effectiveURL: manifestURL)
        XCTAssertFalse(manifest.isWidevine)
        XCTAssertTrue(try XCTUnwrap(manifest.allContentProtections.first).containsMalformedPSSH)
        XCTAssertTrue(manifest.psshBoxes.isEmpty)
    }

    func testParsesLicenseURLAttributeAndRejectsCredentials() throws {
        let xml = """
        <MPD><Period><AdaptationSet>
          <ContentProtection schemeIdUri="urn:uuid:9a04f079-9840-4286-ab92-e65be0885f95"
              licenseUrl="https://license.example/playready" />
          <ContentProtection schemeIdUri="urn:uuid:\(DASHManifestParser.widevineSystemID)"
              licenseUrl="https://license.example/wv" />
          <ContentProtection schemeIdUri="urn:example"
              licenseUrl="https://user:password@evil.example/wv" />
        </AdaptationSet></Period></MPD>
        """

        let manifest = try DASHManifestParser.parse(text: xml, effectiveURL: manifestURL)
        XCTAssertEqual(
            manifest.licenseURLs.map(\.absoluteString),
            ["https://license.example/playready", "https://license.example/wv"]
        )
        XCTAssertEqual(
            manifest.widevineLicenseURLs.map(\.absoluteString),
            ["https://license.example/wv"]
        )
    }

    func testRejectsNonMPDRootAndOversizedInput() throws {
        XCTAssertFalse(DASHManifestParser.isMPD("<html><video /></html>"))
        XCTAssertThrowsError(
            try DASHManifestParser.parse(text: "<html />", effectiveURL: manifestURL)
        ) { error in
            guard let parserError = error as? DASHManifestParserError,
                  case .notMPD = parserError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let spoofedNamespace = "<fake:MPD xmlns:fake=\"urn:example:not-dash\" />"
        XCTAssertFalse(DASHManifestParser.isMPD(spoofedNamespace))
        XCTAssertThrowsError(
            try DASHManifestParser.parse(text: spoofedNamespace, effectiveURL: manifestURL)
        )

        let oversized = Data(repeating: 0x20, count: 4 * 1_024 * 1_024 + 1)
        XCTAssertFalse(DASHManifestParser.isMPD(oversized))
        XCTAssertThrowsError(
            try DASHManifestParser.parse(data: oversized, effectiveURL: manifestURL)
        ) { error in
            guard let parserError = error as? DASHManifestParserError,
                  case .manifestTooLarge = parserError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRejectsDTDAndEntityDeclarations() {
        let xml = """
        <!DOCTYPE MPD [<!ENTITY injected "widevine">]>
        <MPD><Period id="&injected;" /></MPD>
        """

        XCTAssertThrowsError(
            try DASHManifestParser.parse(text: xml, effectiveURL: manifestURL)
        ) { error in
            guard let parserError = error as? DASHManifestParserError,
                  case .invalidXML = parserError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}
