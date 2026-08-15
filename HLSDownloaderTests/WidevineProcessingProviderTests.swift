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
            mediaFileURL: URL(fileURLWithPath: NSTemporaryDirectory())
        )
    }

    func callCount() -> Int { calls }
}
