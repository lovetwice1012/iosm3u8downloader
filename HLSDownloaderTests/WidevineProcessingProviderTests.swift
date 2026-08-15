import Foundation
import XCTest
@testable import HLSDownloader

final class WidevineProcessingProviderTests: XCTestCase {
    func testDefaultProviderFailsWithExplicitUnconfiguredError() async {
        let provider = UnconfiguredWidevineProcessingProvider()
        XCTAssertFalse(provider.isConfigured)
        let manifest = WidevineManifestDocument(
            sourceURL: URL(string: "https://widevine.invalid/manifest.mpd")!,
            data: Data("<MPD/>".utf8)
        )
        let licenseConfiguration = WidevineLicenseConfiguration(
            serverURL: URL(string: "https://license.invalid/request")!,
            httpHeaders: ["Authorization": "private-test-value"]
        )

        do {
            _ = try await provider.process(
                manifest: manifest,
                licenseConfiguration: licenseConfiguration,
                wvdData: Data([0xAA, 0xBB])
            )
            XCTFail("An unconfigured provider must fail")
        } catch let error as WidevineProcessingError {
            XCTAssertEqual(error, .unconfigured)
            XCTAssertFalse(error.localizedDescription.contains("private-test-value"))
            XCTAssertFalse(error.localizedDescription.contains("widevine.invalid"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDomainRestrictedProviderAllowsOnlyCentralPolicyDomain() async throws {
        let base = RecordingWidevineProcessor()
        let provider = DomainRestrictedWidevineProcessingProvider(base: base)
        let allowed = WidevineManifestDocument(
            sourceURL: try XCTUnwrap(
                URL(string: "https://widevine.sprink.cloud/video/manifest.mpd")
            ),
            data: Data("<MPD/>".utf8)
        )
        let license = WidevineLicenseConfiguration(
            serverURL: try XCTUnwrap(
                URL(string: "https://widevine.sprink.cloud/license/request")
            )
        )

        _ = try await provider.process(
            manifest: allowed,
            licenseConfiguration: license,
            wvdData: Data([0x01])
        )
        let callsAfterAllowed = await base.callCount()
        XCTAssertEqual(callsAfterAllowed, 1)

        let blocked = WidevineManifestDocument(
            sourceURL: try XCTUnwrap(URL(string: "https://example.com/video/manifest.mpd")),
            data: Data("<MPD/>".utf8)
        )
        do {
            _ = try await provider.process(
                manifest: blocked,
                licenseConfiguration: license,
                wvdData: Data([0x01])
            )
            XCTFail("A non-allowlisted Widevine manifest must be rejected")
        } catch let error as WidevineProcessingError {
            XCTAssertEqual(error, .domainNotAllowed)
        }
        let callsAfterBlocked = await base.callCount()
        XCTAssertEqual(callsAfterBlocked, 1)

        let externalLicense = WidevineLicenseConfiguration(
            serverURL: try XCTUnwrap(URL(string: "https://license.example/request"))
        )
        do {
            _ = try await provider.process(
                manifest: allowed,
                licenseConfiguration: externalLicense,
                wvdData: Data([0x01])
            )
            XCTFail("A Widevine license endpoint outside the central allowlist must be rejected")
        } catch let error as WidevineProcessingError {
            XCTAssertEqual(error, .domainNotAllowed)
        }
        let callsAfterExternalLicense = await base.callCount()
        XCTAssertEqual(callsAfterExternalLicense, 1)
    }

    @MainActor
    func testDownloadServicePublishesAudioOnlyWidevineResultAsWAV() async throws {
        let processor = StaticWidevineOutputProcessor(
            outputData: servicePCM16WAVData(),
            outputFormat: .wav
        )
        let service = HLSDownloadService(
            client: HTTPClient(configuration: .ephemeral),
            widevineCredentialStore: StaticWidevineCredentialStore(),
            widevineProcessor: processor
        )

        let result = try await service.download(
            candidate: serviceCandidate(),
            progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        XCTAssertEqual(result.outputURL.pathExtension, "wav")
        XCTAssertEqual(try Data(contentsOf: result.outputURL), servicePCM16WAVData())
        XCTAssertTrue(WidevineMediaOutputValidator.isValid(result.outputURL, format: .wav))
    }

    @MainActor
    func testDownloadServiceKeepsVideoWidevineResultAsMP4() async throws {
        let processor = StaticWidevineOutputProcessor(
            outputData: serviceMP4Data(),
            outputFormat: .mp4
        )
        let service = HLSDownloadService(
            client: HTTPClient(configuration: .ephemeral),
            widevineCredentialStore: StaticWidevineCredentialStore(),
            widevineProcessor: processor
        )

        let result = try await service.download(
            candidate: serviceCandidate(),
            progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        XCTAssertEqual(result.outputURL.pathExtension, "mp4")
        XCTAssertEqual(try Data(contentsOf: result.outputURL), serviceMP4Data())
        XCTAssertTrue(WidevineMediaOutputValidator.isValid(result.outputURL, format: .mp4))
    }

    @MainActor
    func testDownloadServiceRejectsOutputThatDoesNotMatchDeclaredFormat() async throws {
        let service = HLSDownloadService(
            client: HTTPClient(configuration: .ephemeral),
            widevineCredentialStore: StaticWidevineCredentialStore(),
            widevineProcessor: StaticWidevineOutputProcessor(
                outputData: serviceMP4Data(),
                outputFormat: .wav
            )
        )

        do {
            _ = try await service.download(
                candidate: serviceCandidate(),
                progress: { _ in }
            )
            XCTFail("An MP4 payload declared as WAV must not reach final storage")
        } catch let error as WidevineProcessingError {
            XCTAssertEqual(error, .invalidOutput)
        }
    }

    private func serviceCandidate() -> HLSCandidate {
        let manifestURL = URL(
            string: "https://widevine.sprink.cloud/video/audio-only.mpd"
        )!
        let manifest = #"""
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">
          <Period>
            <AdaptationSet contentType="audio" mimeType="audio/mp4">
              <ContentProtection
                  schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"
                  licenseUrl="https://widevine.sprink.cloud/license/acquire" />
              <Representation id="audio" bandwidth="128000" />
            </AdaptationSet>
          </Period>
        </MPD>
        """#
        return HLSCandidate(
            id: UUID(),
            kind: .widevineDASH,
            request: URLCandidates(primary: manifestURL, sameOriginQueryFallback: nil),
            requestReferer: nil,
            document: PlaylistDocument(
                text: manifest,
                effectiveURL: manifestURL,
                referer: nil
            ),
            pageURL: manifestURL,
            title: nil,
            thumbnailURL: nil,
            iframeDepth: 0,
            origin: .direct
        )
    }
}

private actor RecordingWidevineProcessor: WidevineProcessingProviding {
    nonisolated let isConfigured = true
    private var calls = 0

    func process(
        manifest: WidevineManifestDocument,
        licenseConfiguration: WidevineLicenseConfiguration,
        wvdData: Data
    ) async throws -> WidevineProcessingResult {
        calls += 1
        return WidevineProcessingResult(
            mediaFileURL: URL(fileURLWithPath: NSTemporaryDirectory()),
            outputFormat: .mp4
        )
    }

    func callCount() -> Int { calls }
}

private struct StaticWidevineCredentialStore: WidevineCredentialStoring {
    func save(_ wvdData: Data) throws {}
    func load() throws -> Data? { Data([0x57, 0x56, 0x44]) }
    func delete() throws {}
}

private struct StaticWidevineOutputProcessor: WidevineProcessingProviding {
    let outputData: Data
    let outputFormat: MediaOutputFormat
    let isConfigured = true

    func process(
        manifest: WidevineManifestDocument,
        licenseConfiguration: WidevineLicenseConfiguration,
        wvdData: Data
    ) async throws -> WidevineProcessingResult {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "widevine-service-output-\(UUID().uuidString).\(outputFormat.rawValue)"
        )
        try outputData.write(to: output, options: .atomic)
        return WidevineProcessingResult(
            mediaFileURL: output,
            outputFormat: outputFormat
        )
    }
}

private func serviceMP4Data() -> Data {
    Data([
        0x00, 0x00, 0x00, 0x18,
        0x66, 0x74, 0x79, 0x70,
        0x69, 0x73, 0x6F, 0x6D,
        0x00, 0x00, 0x02, 0x00,
        0x69, 0x73, 0x6F, 0x6D,
        0x69, 0x73, 0x6F, 0x32
    ])
}

private func servicePCM16WAVData() -> Data {
    var data = Data("RIFF".utf8)
    data.append(contentsOf: [38, 0, 0, 0])
    data.append(Data("WAVE".utf8))
    data.append(Data("fmt ".utf8))
    data.append(contentsOf: [16, 0, 0, 0])
    data.append(contentsOf: [1, 0, 1, 0])
    data.append(contentsOf: [0x40, 0x1F, 0, 0])
    data.append(contentsOf: [0x80, 0x3E, 0, 0])
    data.append(contentsOf: [2, 0, 16, 0])
    data.append(Data("data".utf8))
    data.append(contentsOf: [2, 0, 0, 0, 0, 0])
    return data
}
