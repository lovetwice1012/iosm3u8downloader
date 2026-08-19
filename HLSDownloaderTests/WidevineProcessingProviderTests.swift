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

    @MainActor
    func testDownloadServiceRejectsIncompleteEncryptedAndTracklessMP4Outputs() async throws {
        let fileTypeOnly = isoBox("ftyp", payload: Data("isom0000".utf8))
        let emptyMovie = fileTypeOnly
            + isoBox("moov", payload: Data())
            + isoBox("mdat", payload: Data([0x01]))
        let metadataOnlyTrack = structuredMP4Data()
        let corruptSamples = corruptedServiceMP4Data()
        let encrypted = structuredMP4Data(
            additionalMoviePayload: isoBox(
                "pssh",
                payload: Data(repeating: 0, count: 24)
            )
        )

        for invalidOutput in [
            fileTypeOnly,
            emptyMovie,
            metadataOnlyTrack,
            corruptSamples,
            encrypted
        ] {
            let service = HLSDownloadService(
                client: HTTPClient(configuration: .ephemeral),
                widevineCredentialStore: StaticWidevineCredentialStore(),
                widevineProcessor: StaticWidevineOutputProcessor(
                    outputData: invalidOutput,
                    outputFormat: .mp4
                )
            )

            do {
                _ = try await service.download(
                    candidate: serviceCandidate(),
                    progress: { _ in }
                )
                XCTFail("An incomplete or encrypted MP4 must not reach final storage")
            } catch let error as WidevineProcessingError {
                XCTAssertEqual(error, .invalidOutput)
            }
        }
    }

    func testMP4ValidatorRequiresCompleteClearMediaStructure() throws {
        let clear = serviceMP4Data()
        let fileTypeOnly = isoBox("ftyp", payload: Data("isom0000".utf8))
        let emptyMovie = fileTypeOnly
            + isoBox("moov", payload: Data())
            + isoBox("mdat", payload: Data([0x01]))
        let noMediaData = structuredMP4Data(includeMediaData: false)
        let emptyMediaData = noMediaData + isoBox("mdat", payload: Data())
        let encrypted = structuredMP4Data(
            additionalMoviePayload: isoBox(
                "schm",
                payload: Data([0, 0, 0, 0]) + Data("cenc".utf8)
            )
        )
        let residualProtectionMetadata = ["sgpd", "sbgp", "ipro"].map {
            structuredMP4Data(
                additionalMoviePayload: isoBox($0, payload: Data(repeating: 0, count: 8))
            )
        }
        let unknownUUID = structuredMP4Data(
            additionalMoviePayload: isoBox(
                "uuid",
                payload: Data(repeating: 0x11, count: 16)
            )
        )
        var truncated = clear
        truncated.removeLast()
        let fixtures = [
            clear,
            fileTypeOnly,
            emptyMovie,
            noMediaData,
            emptyMediaData,
            encrypted,
            unknownUUID,
            truncated
        ] + residualProtectionMetadata
        let fixtureURLs = try fixtures.map {
            try writeMediaFixture($0, extension: "mp4")
        }
        defer { fixtureURLs.forEach { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertTrue(WidevineMediaOutputValidator.isValid(fixtureURLs[0], format: .mp4))
        for fixture in fixtureURLs.dropFirst() {
            XCTAssertFalse(WidevineMediaOutputValidator.isValid(fixture, format: .mp4))
        }
    }

    func testWidevineFinalDecodeGateRejectsCorruptSamplesAfterMetadataProbePasses() async throws {
        let clearURL = try writeMediaFixture(serviceMP4Data(), extension: "mp4")
        let corruptURL = try writeMediaFixture(corruptedServiceMP4Data(), extension: "mp4")
        defer {
            try? FileManager.default.removeItem(at: clearURL)
            try? FileManager.default.removeItem(at: corruptURL)
        }

        XCTAssertTrue(WidevineMediaOutputValidator.isValid(clearURL, format: .mp4))
        XCTAssertTrue(WidevineMediaOutputValidator.isValid(corruptURL, format: .mp4))
        let corruptTracks = try await LocalMediaTrackProbe().probe(
            inputURL: corruptURL,
            input: .mediaFile()
        )
        XCTAssertTrue(corruptTracks.contains(.video))

        try await WidevineMediaDecodeValidator().validate(
            inputURL: clearURL,
            expectedTracks: .video
        )
        do {
            try await WidevineMediaDecodeValidator().validate(
                inputURL: corruptURL,
                expectedTracks: .video
            )
            XCTFail("Corrupt media samples must fail the full-decode gate")
        } catch let error as WidevineProcessingError {
            XCTAssertEqual(error, .invalidOutput)
        }
    }

    func testWAVValidatorRequiresDeclaredWholeFileBounds() throws {
        let clear = servicePCM16WAVData()
        var truncated = clear
        truncated.removeLast()
        var trailing = clear
        trailing.append(0)
        let fixtures = try [clear, truncated, trailing].map {
            try writeMediaFixture($0, extension: "wav")
        }
        defer { fixtures.forEach { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertTrue(WidevineMediaOutputValidator.isValid(fixtures[0], format: .wav))
        XCTAssertFalse(WidevineMediaOutputValidator.isValid(fixtures[1], format: .wav))
        XCTAssertFalse(WidevineMediaOutputValidator.isValid(fixtures[2], format: .wav))
    }

    func testWebMValidatorRequiresCompleteWebMAndRejectsContentEncryption() throws {
        let clearURL = try writeMediaFixture(webMFixture(encrypted: false), extension: "webm")
        let encryptedURL = try writeMediaFixture(webMFixture(encrypted: true), extension: "webm")
        let encryptedBlockURL = try writeMediaFixture(
            webMEncryptedBlockFixture(),
            extension: "webm"
        )
        let emptyClusterURL = try writeMediaFixture(
            webMEmptyClusterFixture(),
            extension: "webm"
        )
        let misplacedBlockURL = try writeMediaFixture(
            webMMisplacedBlockFixture(),
            extension: "webm"
        )
        let hiddenEncryptedBlockURL = try writeMediaFixture(
            webMUnknownSizeLeafHidingEncryptedBlockFixture(),
            extension: "webm"
        )
        var truncated = webMFixture(encrypted: false)
        truncated.removeLast()
        let truncatedURL = try writeMediaFixture(truncated, extension: "webm")
        defer {
            for url in [
                clearURL,
                encryptedURL,
                encryptedBlockURL,
                emptyClusterURL,
                misplacedBlockURL,
                hiddenEncryptedBlockURL,
                truncatedURL
            ] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        XCTAssertEqual(
            ProgressiveMediaProtectionInspector.inspect(clearURL, container: .webM),
            .clear
        )
        XCTAssertTrue(WidevineMediaOutputValidator.isValid(clearURL, format: .webm))
        XCTAssertEqual(
            ProgressiveMediaProtectionInspector.inspect(encryptedURL, container: .webM),
            .encrypted
        )
        XCTAssertFalse(WidevineMediaOutputValidator.isValid(encryptedURL, format: .webm))
        XCTAssertEqual(
            ProgressiveMediaProtectionInspector.inspect(encryptedBlockURL, container: .webM),
            .encrypted
        )
        XCTAssertFalse(WidevineMediaOutputValidator.isValid(encryptedBlockURL, format: .webm))
        XCTAssertEqual(
            ProgressiveMediaProtectionInspector.inspect(emptyClusterURL, container: .webM),
            .invalid
        )
        XCTAssertFalse(WidevineMediaOutputValidator.isValid(emptyClusterURL, format: .webm))
        XCTAssertEqual(
            ProgressiveMediaProtectionInspector.inspect(misplacedBlockURL, container: .webM),
            .invalid
        )
        XCTAssertFalse(WidevineMediaOutputValidator.isValid(misplacedBlockURL, format: .webm))
        XCTAssertEqual(
            ProgressiveMediaProtectionInspector.inspect(
                hiddenEncryptedBlockURL,
                container: .webM
            ),
            .invalid
        )
        XCTAssertFalse(
            WidevineMediaOutputValidator.isValid(hiddenEncryptedBlockURL, format: .webm)
        )
        XCTAssertEqual(
            ProgressiveMediaProtectionInspector.inspect(truncatedURL, container: .webM),
            .invalid
        )
        XCTAssertFalse(WidevineMediaOutputValidator.isValid(truncatedURL, format: .webm))
    }

    func testWebMValidatorSupportsMoreThanLegacyHundredThousandElementLimit() throws {
        let docType = webMElement([0x42, 0x82], payload: Data("webm".utf8))
        let header = webMElement([0x1A, 0x45, 0xDF, 0xA3], payload: docType)
        let simpleBlock = webMElement([0xA3], payload: Data([0x81, 0, 0, 0, 1]))
        var fixture = Data()
        fixture.reserveCapacity(header.count + 12 + simpleBlock.count * 100_001)
        fixture.append(header)
        fixture.append(contentsOf: [0x18, 0x53, 0x80, 0x67, 0xFF])
        fixture.append(contentsOf: [0x1F, 0x43, 0xB6, 0x75, 0xFF])
        for _ in 0..<100_001 { fixture.append(simpleBlock) }

        let url = try writeMediaFixture(fixture, extension: "webm")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(
            ProgressiveMediaProtectionInspector.inspect(url, container: .webM),
            .clear
        )
        XCTAssertTrue(WidevineMediaOutputValidator.isValid(url, format: .webm))
    }

    func testISOBMFFProtectionInspectorRejectsPSSHCBCSAndTruncation() throws {
        let fileType = isoBox("ftyp", payload: Data("isom0000".utf8))
        let clear = fileType + isoBox("moov", payload: Data())
        let pssh = fileType + isoBox(
            "moov",
            payload: isoBox("pssh", payload: Data(repeating: 0, count: 24))
        )
        let cbcs = fileType + isoBox(
            "moov",
            payload: isoBox("schm", payload: Data([0, 0, 0, 0]) + Data("cbcs".utf8))
        )
        let residualProtectionMetadata = ["sgpd", "sbgp", "ipro"].map {
            fileType + isoBox(
                "moov",
                payload: isoBox($0, payload: Data(repeating: 0, count: 8))
            )
        }
        let unknownUUID = fileType + isoBox(
            "moov",
            payload: isoBox("uuid", payload: Data(repeating: 0x11, count: 16))
        )
        var truncated = clear
        truncated[truncated.count - 8] = 0
        truncated[truncated.count - 7] = 0
        truncated[truncated.count - 6] = 0
        truncated[truncated.count - 5] = 16

        let fixtures = try ([clear, pssh, cbcs, unknownUUID]
            + residualProtectionMetadata
            + [truncated]).map {
            try writeMediaFixture($0, extension: "mp4")
        }
        defer { fixtures.forEach { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertEqual(
            ProgressiveMediaProtectionInspector.inspect(fixtures[0], container: .isoBaseMedia),
            .clear
        )
        for fixture in fixtures[1...6] {
            XCTAssertEqual(
                ProgressiveMediaProtectionInspector.inspect(fixture, container: .isoBaseMedia),
                .encrypted
            )
        }
        XCTAssertEqual(
            ProgressiveMediaProtectionInspector.inspect(fixtures[7], container: .isoBaseMedia),
            .invalid
        )
    }

    func testStandaloneSampleAESCapableFramedMediaIsFailClosed() throws {
        var transportStream = Data(repeating: 0, count: 188 * 3)
        for offset in stride(from: 0, to: transportStream.count, by: 188) {
            transportStream[offset] = 0x47
            transportStream[offset + 3] = 0x10
        }
        let fixture = try writeMediaFixture(transportStream, extension: "ts")
        defer { try? FileManager.default.removeItem(at: fixture) }

        for container in [
            MediaContainer.transportStream,
            .aac,
            .ac3,
            .eac3
        ] {
            XCTAssertEqual(
                ProgressiveMediaProtectionInspector.inspect(fixture, container: container),
                .invalid
            )
            XCTAssertFalse(ProgressiveMediaDetector.supportsStandaloneDownload(container))
        }
        XCTAssertTrue(ProgressiveMediaDetector.supportsStandaloneDownload(.mp3))
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
    Data(
        base64Encoded: "AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAA0Ftb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAD6AABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACa3RyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAD6AAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAEAAAABAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAA+gAAAAAAAEAAAAAAeNtZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAAEAAAABAAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAAGObWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAABTnN0YmwAAADqc3RzZAAAAAAAAAABAAAA2m1wNHYAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAEAAQAEgAAABIAAAAAAAAAAETTGF2YzYyLjI4LjEwMCBtcGVnNAAAAAAAAAAAAAAAAAAY//8AAABgZXNkcwAAAAADgICATwABAASAgIBBIBEAAAAAAw1AAAAAiAWAgIAvAAABsAEAAAG1iRMAAAEAAAABIADEjYgADQCEAhRjAAABskxhdmM2Mi4yOC4xMDAGgICAAQIAAAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAAMNQAAAAIgAAAAYc3R0cwAAAAAAAAABAAAAAQAAQAAAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAEAAAABAAAAFHN0c3oAAAAAAAAAEQAAAAEAAAAUc3RjbwAAAAAAAAABAAADbQAAAGJ1ZHRhAAAAWm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAAAQAAAABMYXZmNjIuMTIuMTAwAAAACGZyZWUAAAAZbWRhdAAAAbMAEAcAAAG2Fj8Ysbfv"
    )!
}

private func corruptedServiceMP4Data() -> Data {
    var data = serviceMP4Data()
    guard let mediaDataType = data.range(of: Data("mdat".utf8)),
          mediaDataType.upperBound < data.endIndex else {
        preconditionFailure("The MP4 fixture must contain non-empty media data")
    }
    for index in mediaDataType.upperBound..<data.endIndex {
        data[index] = 0
    }
    return data
}

private func structuredMP4Data(
    additionalMoviePayload: Data = Data(),
    includeMediaData: Bool = true
) -> Data {
    let fileType = isoBox("ftyp", payload: Data("isom0000".utf8))
    let sampleTable = isoBox("stbl", payload: Data())
    let mediaInformation = isoBox("minf", payload: sampleTable)
    let media = isoBox("mdia", payload: mediaInformation)
    let movie = isoBox(
        "moov",
        payload: isoBox("trak", payload: media) + additionalMoviePayload
    )
    return fileType
        + movie
        + (includeMediaData ? isoBox("mdat", payload: Data([0x01])) : Data())
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

private func writeMediaFixture(_ data: Data, extension pathExtension: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "progressive-fixture-\(UUID().uuidString).\(pathExtension)"
    )
    try data.write(to: url, options: .atomic)
    return url
}

private func isoBox(_ type: String, payload: Data) -> Data {
    precondition(type.utf8.count == 4)
    let size = UInt32(payload.count + 8)
    var result = Data([
        UInt8((size >> 24) & 0xff),
        UInt8((size >> 16) & 0xff),
        UInt8((size >> 8) & 0xff),
        UInt8(size & 0xff)
    ])
    result.append(Data(type.utf8))
    result.append(payload)
    return result
}

private func webMElement(_ identifier: [UInt8], payload: Data) -> Data {
    precondition(!identifier.isEmpty && payload.count < 127)
    var result = Data(identifier)
    result.append(UInt8(0x80 | payload.count))
    result.append(payload)
    return result
}

private func webMFixture(encrypted: Bool) -> Data {
    let docType = webMElement([0x42, 0x82], payload: Data("webm".utf8))
    let header = webMElement([0x1A, 0x45, 0xDF, 0xA3], payload: docType)
    let tracks: Data
    if encrypted {
        let encryption = webMElement([0x50, 0x35], payload: Data())
        let encoding = webMElement([0x62, 0x40], payload: encryption)
        let encodings = webMElement([0x6D, 0x80], payload: encoding)
        let track = webMElement([0xAE], payload: encodings)
        tracks = webMElement([0x16, 0x54, 0xAE, 0x6B], payload: track)
    } else {
        tracks = webMElement(
            [0x16, 0x54, 0xAE, 0x6B],
            payload: webMElement([0xAE], payload: Data())
        )
    }
    let simpleBlock = webMElement([0xA3], payload: Data([0x81, 0, 0, 0, 1]))
    let cluster = webMElement([0x1F, 0x43, 0xB6, 0x75], payload: simpleBlock)
    let segmentPayload = tracks + cluster
    return header + webMElement([0x18, 0x53, 0x80, 0x67], payload: segmentPayload)
}

private func webMEncryptedBlockFixture() -> Data {
    let docType = webMElement([0x42, 0x82], payload: Data("webm".utf8))
    let header = webMElement([0x1A, 0x45, 0xDF, 0xA3], payload: docType)
    let encryptedBlock = webMElement([0xAF], payload: Data([0x81, 0, 0, 0, 1]))
    let cluster = webMElement([0x1F, 0x43, 0xB6, 0x75], payload: encryptedBlock)
    return header + webMElement([0x18, 0x53, 0x80, 0x67], payload: cluster)
}

private func webMEmptyClusterFixture() -> Data {
    let docType = webMElement([0x42, 0x82], payload: Data("webm".utf8))
    let header = webMElement([0x1A, 0x45, 0xDF, 0xA3], payload: docType)
    let tracks = webMElement(
        [0x16, 0x54, 0xAE, 0x6B],
        payload: webMElement([0xAE], payload: Data())
    )
    let timecode = webMElement([0xE7], payload: Data([0]))
    let cluster = webMElement([0x1F, 0x43, 0xB6, 0x75], payload: timecode)
    return header + webMElement(
        [0x18, 0x53, 0x80, 0x67],
        payload: tracks + cluster
    )
}

private func webMMisplacedBlockFixture() -> Data {
    let docType = webMElement([0x42, 0x82], payload: Data("webm".utf8))
    let header = webMElement([0x1A, 0x45, 0xDF, 0xA3], payload: docType)
    let tracks = webMElement(
        [0x16, 0x54, 0xAE, 0x6B],
        payload: webMElement([0xAE], payload: Data())
    )
    let timecode = webMElement([0xE7], payload: Data([0]))
    let emptyCluster = webMElement([0x1F, 0x43, 0xB6, 0x75], payload: timecode)
    let misplaced = webMElement([0xA3], payload: Data([0x81, 0, 0, 0, 1]))
    return header + webMElement(
        [0x18, 0x53, 0x80, 0x67],
        payload: tracks + emptyCluster + misplaced
    )
}

private func webMUnknownSizeLeafHidingEncryptedBlockFixture() -> Data {
    let docType = webMElement([0x42, 0x82], payload: Data("webm".utf8))
    let header = webMElement([0x1A, 0x45, 0xDF, 0xA3], payload: docType)
    let clearBlock = webMElement([0xA3], payload: Data([0x81, 0, 0, 0, 1]))
    let cluster = webMElement([0x1F, 0x43, 0xB6, 0x75], payload: clearBlock)
    let hiddenEncryptedBlock = webMElement(
        [0xAF],
        payload: Data([0x81, 0, 0, 0, 1])
    )
    var unknownSizeInfo = Data([0x15, 0x49, 0xA9, 0x66, 0xFF])
    unknownSizeInfo.append(hiddenEncryptedBlock)
    return header + webMElement(
        [0x18, 0x53, 0x80, 0x67],
        payload: cluster + unknownSizeInfo
    )
}
