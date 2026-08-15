import Foundation
import XCTest
@testable import HLSDownloader

final class WidevineDASHDownloadProviderTests: XCTestCase {
    private let manifestURL = URL(
        string: "https://widevine.sprink.cloud/video/manifest.mpd"
    )!
    private let pssh = "AAAAIHBzc2gAAAAA7e+LqXnWSs6jyCfc1R0h7QAAAAA="
    private let videoKeyID = "11111111-2222-3333-4444-555555555555"
    private let audioKeyID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    func testPlannerSelectsBestRepresentationsAndExpandsTemplateListAndRanges() throws {
        let manifest = try parsedManifest()
        let plan = try WidevineDASHPlanner().makePlan(manifest: manifest)
        let video = try XCTUnwrap(plan.video)
        let audio = try XCTUnwrap(plan.audio)

        XCTAssertEqual(plan.outputFormat, .mp4)
        XCTAssertEqual(video.representationID, "v-high")
        XCTAssertEqual(video.bandwidth, 2_500_000)
        XCTAssertEqual(video.keyID, videoKeyID)
        XCTAssertEqual(video.scheme, .cenc)
        XCTAssertEqual(
            video.initialization.url.absoluteString,
            "https://widevine.sprink.cloud/video/media/video/v-high/init.mp4"
        )
        XCTAssertEqual(
            video.segments.map(\.url.absoluteString),
            [
                "https://widevine.sprink.cloud/video/media/video/v-high/chunk-$-00007.m4s",
                "https://widevine.sprink.cloud/video/media/video/v-high/chunk-$-00008.m4s",
                "https://widevine.sprink.cloud/video/media/video/v-high/chunk-$-00009.m4s"
            ]
        )
        XCTAssertEqual(audio.representationID, "a-main")
        XCTAssertEqual(audio.keyID, audioKeyID)
        XCTAssertEqual(audio.scheme, .cbcs)
        XCTAssertEqual(
            audio.initialization.url.absoluteString,
            "https://widevine.sprink.cloud/video/media/audio/init.mp4"
        )
        XCTAssertEqual(audio.initialization.byteRange, ByteRange(offset: 0, length: 100))
        XCTAssertEqual(audio.segments.map(\.byteRange), [ByteRange(offset: 100, length: 100), nil])
        XCTAssertEqual(plan.expectedKeyIDs, Set([videoKeyID, audioKeyID]))
        XCTAssertEqual(plan.psshData.count, 1)
    }

    func testPlannerAllowsAudioOnlyWidevinePresentation() throws {
        let manifest = try DASHManifestParser.parse(
            text: audioOnlyManifestXML(),
            effectiveURL: manifestURL
        )

        let plan = try WidevineDASHPlanner().makePlan(manifest: manifest)

        XCTAssertNil(plan.video)
        XCTAssertEqual(plan.outputFormat, .wav)
        XCTAssertEqual(plan.audio?.mediaType, .audio)
        XCTAssertEqual(plan.audio?.representationID, "a-main")
        XCTAssertEqual(plan.expectedKeyIDs, Set([audioKeyID]))
        XCTAssertEqual(plan.psshData, [try XCTUnwrap(Data(base64Encoded: pssh))])
    }

    func testWAVValidatorRejectsEmptyDataChunkEvenWhenTrailingBytesExist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "widevine-empty-wav-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        var empty = minimalPCM16WAVData()
        empty.replaceSubrange(40..<44, with: [0, 0, 0, 0])
        let output = directory.appendingPathComponent("empty.wav")
        try empty.write(to: output)

        XCTAssertFalse(WidevineMediaOutputValidator.isValid(output, format: .wav))
        XCTAssertFalse(WidevineMediaOutputValidator.isValid(output, format: .mp4))
    }

    func testPlannerRejectsDynamicMultiplePeriodsAndKeyRotation() throws {
        let dynamic = try DASHManifestParser.parse(
            text: manifestXML().replacingOccurrences(of: #"type="static""#, with: #"type="dynamic""#),
            effectiveURL: manifestURL
        )
        XCTAssertThrowsError(try WidevineDASHPlanner().makePlan(manifest: dynamic)) {
            XCTAssertEqual($0 as? WidevineDASHProviderError, .dynamicPresentationUnsupported)
        }

        let multiplePeriodsXML = manifestXML().replacingOccurrences(
            of: "</MPD>",
            with: #"<Period><AdaptationSet contentType="video"><Representation id="extra" mimeType="video/mp4" /></AdaptationSet></Period></MPD>"#
        )
        let multiplePeriods = try DASHManifestParser.parse(
            text: multiplePeriodsXML,
            effectiveURL: manifestURL
        )
        XCTAssertThrowsError(try WidevineDASHPlanner().makePlan(manifest: multiplePeriods)) {
            XCTAssertEqual($0 as? WidevineDASHProviderError, .multiplePeriodsUnsupported)
        }

        let rotationXML = manifestXML().replacingOccurrences(
            of: #"cenc:default_KID="11111111-2222-3333-4444-555555555555""#,
            with: #"cenc:default_KID="11111111-2222-3333-4444-555555555555 99999999-2222-3333-4444-555555555555""#
        )
        let rotation = try DASHManifestParser.parse(text: rotationXML, effectiveURL: manifestURL)
        XCTAssertThrowsError(try WidevineDASHPlanner().makePlan(manifest: rotation)) {
            XCTAssertEqual($0 as? WidevineDASHProviderError, .keyRotationUnsupported)
        }

        let overflowingRangeXML = manifestXML()
            .replacingOccurrences(
                of: #"timescale="1000" startNumber="7""#,
                with: #"timescale="1000" startNumber="0" endNumber="18446744073709551615" duration="4000""#
            )
            .replacingOccurrences(
                of: #"<SegmentTimeline><S t="0" d="4000" r="2" /></SegmentTimeline>"#,
                with: ""
            )
        let overflowingRange = try DASHManifestParser.parse(
            text: overflowingRangeXML,
            effectiveURL: manifestURL
        )
        XCTAssertThrowsError(try WidevineDASHPlanner().makePlan(manifest: overflowingRange)) {
            XCTAssertEqual($0 as? WidevineDASHProviderError, .invalidSegmentTemplate)
        }
    }

    func testPlannerExcludesPSSHFromUnselectedRepresentations() throws {
        let unrelatedPSSH = "AAAAIXBzc2gAAAAA7e+LqXnWSs6jyCfc1R0h7QAAAAEB"
        let xml = manifestXML().replacingOccurrences(
            of: "</Period>",
            with: #"""
            <AdaptationSet contentType="text" mimeType="application/mp4">
              <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed">
                <cenc:pssh>\#(unrelatedPSSH)</cenc:pssh>
              </ContentProtection>
              <Representation id="subtitle" bandwidth="1000" />
            </AdaptationSet>
            </Period>
            """#
        )
        let manifest = try DASHManifestParser.parse(text: xml, effectiveURL: manifestURL)
        XCTAssertEqual(manifest.psshBoxes.count, 2)

        let plan = try WidevineDASHPlanner().makePlan(manifest: manifest)
        XCTAssertEqual(plan.psshData.count, 1)
        XCTAssertEqual(plan.psshData.first, Data(base64Encoded: pssh))
    }

    func testPlannerAllowsMissingRepresentationIDForSegmentListButNotTemplateToken() throws {
        let listWithoutID = try DASHManifestParser.parse(
            text: manifestXML().replacingOccurrences(
                of: #"<Representation id="a-main" bandwidth="128000">"#,
                with: #"<Representation bandwidth="128000">"#
            ),
            effectiveURL: manifestURL
        )
        let listPlan = try WidevineDASHPlanner().makePlan(manifest: listWithoutID)
        XCTAssertEqual(listPlan.audio?.representationID, "")
        XCTAssertEqual(listPlan.audio?.segments.count, 2)

        let templateWithoutID = try DASHManifestParser.parse(
            text: manifestXML().replacingOccurrences(
                of: #"<Representation id="v-high" bandwidth="2500000" width="1920" height="1080" />"#,
                with: #"<Representation bandwidth="2500000" width="1920" height="1080" />"#
            ),
            effectiveURL: manifestURL
        )
        XCTAssertThrowsError(try WidevineDASHPlanner().makePlan(manifest: templateWithoutID)) {
            XCTAssertEqual($0 as? WidevineDASHProviderError, .invalidSegmentTemplate)
        }
    }

    func testProviderDownloadsInParallelConsolidatesTracksAndPassesPerTrackKeys() async throws {
        let fetcher = RecordingDASHFetcher()
        let acquirer = RecordingKeyAcquirer(
            keys: [
                try contentKey(keyID: videoKeyID, value: 0x11),
                try contentKey(keyID: audioKeyID, value: 0xAA)
            ]
        )
        let composer = RecordingMediaComposer()
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "widevine-provider-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let provider = WidevineDASHDownloadProvider(
            segmentFetcher: fetcher,
            keyAcquirer: acquirer,
            mediaComposer: composer,
            temporaryRoot: temporaryRoot,
            maximumParallelDownloads: 4
        )
        XCTAssertTrue(provider.isConfigured)
        let result = try await provider.process(
            manifest: WidevineManifestDocument(
                sourceURL: manifestURL,
                data: Data(manifestXML().utf8)
            ),
            licenseConfiguration: WidevineLicenseConfiguration(
                serverURL: URL(string: "https://widevine.sprink.cloud/license/acquire")!
            ),
            wvdData: Data([0x57, 0x56, 0x44])
        )
        defer { try? FileManager.default.removeItem(at: result.mediaFileURL) }

        XCTAssertEqual(try Data(contentsOf: result.mediaFileURL), minimalMP4Data())
        XCTAssertEqual(result.outputFormat, .mp4)
        XCTAssertEqual(result.mediaFileURL.pathExtension, "mp4")
        XCTAssertTrue(result.mediaFileURL.deletingLastPathComponent().lastPathComponent.hasPrefix("job-"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: result.mediaFileURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("encrypted", isDirectory: true)
                    .path
            )
        )
        let acquisition = await acquirer.snapshot()
        XCTAssertEqual(acquisition.expectedKeyIDs, Set([videoKeyID, audioKeyID]))
        XCTAssertEqual(acquisition.initDataCount, 1)
        let composition = await composer.snapshot()
        XCTAssertEqual(
            composition.videoData,
            SyntheticEncryptedFMP4.initialization(
                keyID: videoKeyID,
                tencVersion: 0,
                mediaType: .video
            )
                + SyntheticEncryptedFMP4.fragment(payload: Data("video-7".utf8))
                + SyntheticEncryptedFMP4.fragment(payload: Data("video-8".utf8))
                + SyntheticEncryptedFMP4.fragment(payload: Data("video-9".utf8))
        )
        XCTAssertEqual(
            composition.audioData,
            SyntheticEncryptedFMP4.initialization(
                keyID: audioKeyID,
                tencVersion: 1,
                mediaType: .audio
            )
                + SyntheticEncryptedFMP4.fragment(payload: Data("audio-1".utf8))
                + SyntheticEncryptedFMP4.fragment(payload: Data("audio-2".utf8))
        )
        XCTAssertEqual(composition.videoKey, Data(repeating: 0x11, count: 16))
        XCTAssertEqual(composition.audioKey, Data(repeating: 0xAA, count: 16))
        XCTAssertEqual(composition.videoScheme, .cenc)
        XCTAssertEqual(composition.audioScheme, .cbcs)
        let maximumConcurrentRequests = await fetcher.maximumConcurrentRequests()
        let requestedRanges = await fetcher.requestedRanges()
        let requestedMaximumBytes = await fetcher.requestedMaximumBytes()
        XCTAssertGreaterThan(maximumConcurrentRequests, 1)
        XCTAssertLessThanOrEqual(maximumConcurrentRequests, 3)
        XCTAssertEqual(
            requestedMaximumBytes,
            Set([48 * 1_024 * 1_024])
        )
        XCTAssertEqual(
            requestedRanges,
            [ByteRange(offset: 0, length: 100), ByteRange(offset: 100, length: 100)]
        )
    }

    func testProviderEmitsPCM16WAVForAudioOnlyPresentation() async throws {
        let fetcher = RecordingDASHFetcher()
        let acquirer = RecordingKeyAcquirer(
            keys: [try contentKey(keyID: audioKeyID, value: 0xAA)]
        )
        let composer = RecordingMediaComposer(outputData: minimalPCM16WAVData())
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "widevine-audio-only-provider-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let provider = WidevineDASHDownloadProvider(
            segmentFetcher: fetcher,
            keyAcquirer: acquirer,
            mediaComposer: composer,
            temporaryRoot: temporaryRoot,
            maximumParallelDownloads: 2
        )
        let result = try await provider.process(
            manifest: WidevineManifestDocument(
                sourceURL: manifestURL,
                data: Data(audioOnlyManifestXML().utf8)
            ),
            licenseConfiguration: WidevineLicenseConfiguration(
                serverURL: URL(string: "https://widevine.sprink.cloud/license/acquire")!
            ),
            wvdData: Data([0x57, 0x56, 0x44])
        )
        defer { try? FileManager.default.removeItem(at: result.mediaFileURL) }

        XCTAssertEqual(result.outputFormat, .wav)
        XCTAssertEqual(result.mediaFileURL.pathExtension, "wav")
        XCTAssertEqual(try Data(contentsOf: result.mediaFileURL), minimalPCM16WAVData())
        XCTAssertTrue(
            WidevineMediaOutputValidator.isValid(result.mediaFileURL, format: .wav)
        )

        let acquisition = await acquirer.snapshot()
        XCTAssertEqual(acquisition.expectedKeyIDs, Set([audioKeyID]))
        let composition = await composer.snapshot()
        XCTAssertNil(composition.videoData)
        XCTAssertNotNil(composition.audioData)
        XCTAssertNil(composition.videoKey)
        XCTAssertEqual(composition.audioKey, Data(repeating: 0xAA, count: 16))
        XCTAssertEqual(composition.audioScheme, .cbcs)
    }

    func testStartupCleanupRemovesOnlyProviderJobDirectories() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "widevine-provider-cleanup-test-\(UUID().uuidString)",
            isDirectory: true
        )
        let artifactRoot = temporaryRoot.appendingPathComponent(
            "HLSDownloader-Widevine",
            isDirectory: true
        )
        let abandoned = artifactRoot.appendingPathComponent(
            "job-\(UUID().uuidString)",
            isDirectory: true
        )
        let unrelated = artifactRoot.appendingPathComponent("keep-me", isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("clear".utf8).write(to: abandoned.appendingPathComponent("output.mp4"))
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try WidevineDASHDownloadProvider.cleanupArtifacts(in: temporaryRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testProtectedCopyAndIncompleteExportCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "widevine-protected-copy-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.mp4")
        let partial = directory.appendingPathComponent(".video.part.mp4")
        let unrelated = directory.appendingPathComponent("keep.mp4")
        let payload = Data(repeating: 0x5A, count: 2 * 1_024 * 1_024 + 17)
        try payload.write(to: source)
        try Data("keep".utf8).write(to: unrelated)

        try await FileStore().copyProtectedFile(from: source, to: partial)
        XCTAssertEqual(try Data(contentsOf: partial), payload)
        let attributes = try FileManager.default.attributesOfItem(atPath: partial.path)
        let reportedProtection = attributes[.protectionKey] as? FileProtectionType
#if targetEnvironment(simulator)
        // Simulator files live on the macOS host filesystem, which can ignore
        // NSFileProtection attributes even when setAttributes succeeds. If the
        // host reports one, it must still be the requested protection class.
        if let reportedProtection {
            XCTAssertEqual(reportedProtection, FileProtectionType.completeUnlessOpen)
        }
#else
        XCTAssertEqual(reportedProtection, FileProtectionType.completeUnlessOpen)
#endif

        try FileStore.cleanupIncompleteExports(in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testDownloadPermitPoolRemovesCancelledWaiter() async throws {
        let pool = DASHDownloadPermitPool(limit: 1)
        try await pool.acquire()
        let waiter = Task {
            try await pool.acquire()
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        waiter.cancel()

        do {
            try await waiter.value
            XCTFail("A cancelled queued download must not acquire a permit")
        } catch is CancellationError {
            // Expected. Completion proves the continuation was resumed.
        }

        await pool.release()
        try await pool.acquire()
        await pool.release()
    }

    func testDownloadPermitPoolReturnsPermitWhenResumedWaiterIsCancelled() async throws {
        for _ in 0..<20 {
            let pool = DASHDownloadPermitPool(limit: 1)
            try await pool.acquire()
            let waiter = Task {
                try await pool.acquire()
                // Deliberately do not release here if acquire returned to an
                // already-cancelled task; acquire itself owns that race.
                guard !Task.isCancelled else { return }
                await pool.release()
            }
            await Task.yield()
            await pool.release()
            waiter.cancel()
            _ = try? await waiter.value

            let permitWasReturned = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    do {
                        try await pool.acquire()
                        await pool.release()
                        return true
                    } catch {
                        return false
                    }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    return false
                }
                let result = await group.next() ?? false
                group.cancelAll()
                return result
            }
            XCTAssertTrue(permitWasReturned)
        }
    }

    func testEncryptionValidatorAcceptsMatchingTencVersionZeroAndOne() throws {
        let directory = try makeEncryptionFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for version in [UInt8(0), UInt8(1)] {
            let url = directory.appendingPathComponent("init-v\(version).mp4")
            try SyntheticEncryptedFMP4.initialization(
                keyID: videoKeyID,
                tencVersion: version,
                mediaType: version == 0 ? .video : .audio,
                useExtendedContainerSize: version == 1
            ).write(to: url)

            XCTAssertNoThrow(
                try WidevineFMP4EncryptionValidator.validateInitialization(
                    at: url,
                    expectedKeyID: videoKeyID
                )
            )
        }
    }

    func testEncryptionValidatorRejectsTencKIDDifferentFromPlannedKID() throws {
        let directory = try makeEncryptionFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("init.mp4")
        try SyntheticEncryptedFMP4.initialization(
            keyID: audioKeyID,
            tencVersion: 0,
            mediaType: .video
        ).write(to: url)

        XCTAssertThrowsError(
            try WidevineFMP4EncryptionValidator.validateInitialization(
                at: url,
                expectedKeyID: videoKeyID
            )
        ) {
            XCTAssertEqual($0 as? WidevineDASHProviderError, .keyRotationUnsupported)
        }
    }

    func testEncryptionValidatorAcceptsSameKIDSeigAndRejectsRotation() throws {
        let directory = try makeEncryptionFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sameKeyURL = directory.appendingPathComponent("same.m4s")
        let rotatedURL = directory.appendingPathComponent("rotated.m4s")
        try SyntheticEncryptedFMP4.fragment(
            payload: Data([0x01]),
            seigKeyID: videoKeyID,
            includeSampleToGroup: true,
            useExtendedContainerSize: true
        ).write(to: sameKeyURL)
        try SyntheticEncryptedFMP4.fragment(
            payload: Data([0x02]),
            seigKeyID: audioKeyID,
            includeSampleToGroup: true
        ).write(to: rotatedURL)

        XCTAssertNoThrow(
            try WidevineFMP4EncryptionValidator.validateMediaFragment(
                at: sameKeyURL,
                expectedKeyID: videoKeyID
            )
        )
        XCTAssertThrowsError(
            try WidevineFMP4EncryptionValidator.validateMediaFragment(
                at: rotatedURL,
                expectedKeyID: videoKeyID
            )
        ) {
            XCTAssertEqual($0 as? WidevineDASHProviderError, .keyRotationUnsupported)
        }
    }

    func testEncryptionValidatorSkipsLargeMdatAndRejectsMalformedBoxBounds() throws {
        let directory = try makeEncryptionFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let largeURL = directory.appendingPathComponent("large.m4s")
        var prefix = SyntheticEncryptedFMP4.fragmentPrefix(useExtendedContainerSize: true)
        prefix.append(SyntheticEncryptedFMP4.openEndedMDATHeader())
        try prefix.write(to: largeURL)
        let handle = try FileHandle(forWritingTo: largeURL)
        try handle.truncate(atOffset: UInt64(40 * 1_024 * 1_024))
        try handle.close()

        XCTAssertNoThrow(
            try WidevineFMP4EncryptionValidator.validateMediaFragment(
                at: largeURL,
                expectedKeyID: videoKeyID
            )
        )

        let malformedURL = directory.appendingPathComponent("malformed.m4s")
        var malformed = Data([0x00, 0x00, 0x01, 0x00])
        malformed.append(Data("moof".utf8))
        malformed.append(Data(repeating: 0, count: 8))
        try malformed.write(to: malformedURL)
        XCTAssertThrowsError(
            try WidevineFMP4EncryptionValidator.validateMediaFragment(
                at: malformedURL,
                expectedKeyID: videoKeyID
            )
        ) {
            XCTAssertEqual($0 as? WidevineDASHProviderError, .invalidEncryptionMetadata)
        }
    }

    func testEncryptionValidatorRejectsUnknownPIFFFragmentMetadata() throws {
        let directory = try makeEncryptionFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("piff.m4s")
        try SyntheticEncryptedFMP4.fragment(
            payload: Data([0x01]),
            includePIFFUUID: true
        ).write(to: url)

        XCTAssertThrowsError(
            try WidevineFMP4EncryptionValidator.validateMediaFragment(
                at: url,
                expectedKeyID: videoKeyID
            )
        ) {
            XCTAssertEqual($0 as? WidevineDASHProviderError, .keyRotationUnsupported)
        }
    }

    func testEncryptionValidatorIgnoresUnrelatedSampleGroups() throws {
        let directory = try makeEncryptionFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("roll-group.m4s")
        try SyntheticEncryptedFMP4.fragmentWithUnrelatedSampleGroups().write(to: url)

        XCTAssertNoThrow(
            try WidevineFMP4EncryptionValidator.validateMediaFragment(
                at: url,
                expectedKeyID: videoKeyID
            )
        )
    }

    func testProviderRejectsInsecureLicenseBeforeLicenseOrSegmentWork() async throws {
        let fetcher = RecordingDASHFetcher()
        let acquirer = RecordingKeyAcquirer(keys: [])
        let composer = RecordingMediaComposer()
        let provider = WidevineDASHDownloadProvider(
            segmentFetcher: fetcher,
            keyAcquirer: acquirer,
            mediaComposer: composer
        )

        do {
            _ = try await provider.process(
                manifest: WidevineManifestDocument(
                    sourceURL: manifestURL,
                    data: Data(manifestXML().utf8)
                ),
                licenseConfiguration: WidevineLicenseConfiguration(
                    serverURL: URL(string: "http://widevine.sprink.cloud/license/acquire")!
                ),
                wvdData: Data([0x01])
            )
            XCTFail("Plain HTTP license endpoints must be rejected")
        } catch let error as WidevineDASHProviderError {
            XCTAssertEqual(error, .insecureLicenseURL)
        }
        let acquisitionCalls = await acquirer.callCount()
        let fetchCalls = await fetcher.callCount()
        XCTAssertEqual(acquisitionCalls, 0)
        XCTAssertEqual(fetchCalls, 0)
    }

    func testPlannerRejectsPlainHTTPSegmentURL() throws {
        let insecureXML = manifestXML().replacingOccurrences(
            of: "<BaseURL>media/</BaseURL>",
            with: "<BaseURL>http://cdn.example/media/</BaseURL>"
        )
        let manifest = try DASHManifestParser.parse(
            text: insecureXML,
            effectiveURL: manifestURL
        )
        XCTAssertThrowsError(try WidevineDASHPlanner().makePlan(manifest: manifest)) {
            XCTAssertEqual($0 as? WidevineDASHProviderError, .unsafeSegmentURL)
        }
    }

    func testProviderRejectsNonMP4ComposerOutput() async throws {
        let fetcher = RecordingDASHFetcher()
        let acquirer = RecordingKeyAcquirer(
            keys: [
                try contentKey(keyID: videoKeyID, value: 0x11),
                try contentKey(keyID: audioKeyID, value: 0xAA)
            ]
        )
        let composer = RecordingMediaComposer(outputData: Data("not-an-mp4-output".utf8))
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "widevine-invalid-output-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let provider = WidevineDASHDownloadProvider(
            segmentFetcher: fetcher,
            keyAcquirer: acquirer,
            mediaComposer: composer,
            temporaryRoot: temporaryRoot
        )

        do {
            _ = try await provider.process(
                manifest: WidevineManifestDocument(
                    sourceURL: manifestURL,
                    data: Data(manifestXML().utf8)
            ),
            licenseConfiguration: WidevineLicenseConfiguration(
                serverURL: URL(string: "https://widevine.sprink.cloud/license/acquire")!
            ),
                wvdData: Data([0x01])
            )
            XCTFail("Non-BMFF output must be rejected")
        } catch let error as WidevineDASHProviderError {
            XCTAssertEqual(error, .invalidMediaOutput)
        }
    }

    func testProviderRejectsOtherManifestDomainBeforeLicenseOrSegmentWork() async throws {
        let fetcher = RecordingDASHFetcher()
        let acquirer = RecordingKeyAcquirer(keys: [])
        let composer = RecordingMediaComposer()
        let provider = WidevineDASHDownloadProvider(
            segmentFetcher: fetcher,
            keyAcquirer: acquirer,
            mediaComposer: composer
        )

        do {
            _ = try await provider.process(
                manifest: WidevineManifestDocument(
                    sourceURL: URL(string: "https://example.com/video/manifest.mpd")!,
                    data: Data(manifestXML().utf8)
            ),
            licenseConfiguration: WidevineLicenseConfiguration(
                serverURL: URL(string: "https://widevine.sprink.cloud/license/acquire")!
            ),
                wvdData: Data([0x01])
            )
            XCTFail("Other Widevine domains must be rejected")
        } catch let error as WidevineProcessingError {
            XCTAssertEqual(error, .domainNotAllowed)
        }
        let acquisitionCalls = await acquirer.callCount()
        let fetchCalls = await fetcher.callCount()
        XCTAssertEqual(acquisitionCalls, 0)
        XCTAssertEqual(fetchCalls, 0)
    }

    func testContentKeyDescriptionNeverPrintsKeyMaterial() throws {
        let key = try contentKey(keyID: videoKeyID, value: 0xFE)
        XCTAssertEqual(String(describing: key), "WidevineContentKey(<redacted>)")
        XCTAssertFalse(String(reflecting: key).contains("254"))

        let reflectedValues = Mirror(reflecting: key).children.map { child in
            String(reflecting: child.value)
        }
        XCTAssertEqual(reflectedValues, [#""<redacted>""#])

        var dumped = ""
        dump(key, to: &dumped)
        XCTAssertTrue(dumped.contains("<redacted>"))
        XCTAssertFalse(dumped.contains(String(repeating: "fe", count: 16)))
        XCTAssertFalse(dumped.contains(key.value.base64EncodedString()))
        XCTAssertFalse(dumped.contains("254"))
    }

    private func parsedManifest() throws -> DASHManifest {
        try DASHManifestParser.parse(text: manifestXML(), effectiveURL: manifestURL)
    }

    private func contentKey(keyID: String, value: UInt8) throws -> WidevineContentKey {
        let uuid = try XCTUnwrap(UUID(uuidString: keyID))
        var bytes = uuid.uuid
        let id = withUnsafeBytes(of: &bytes) { Data($0) }
        return WidevineContentKey(
            id: id,
            value: Data(repeating: value, count: 16),
            type: .content
        )
    }

    private func makeEncryptionFixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "widevine-encryption-metadata-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func manifestXML() -> String {
        #"""
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
             xmlns:cenc="urn:mpeg:cenc:2013"
             type="static"
             mediaPresentationDuration="PT12S">
          <BaseURL>media/</BaseURL>
          <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed">
            <cenc:pssh>\#(pssh)</cenc:pssh>
          </ContentProtection>
          <Period duration="PT12S">
            <AdaptationSet contentType="video" mimeType="video/mp4">
              <ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011"
                  value="cenc" cenc:default_KID="\#(videoKeyID)" />
              <SegmentTemplate timescale="1000" startNumber="7"
                  initialization="video/$RepresentationID$/init.mp4"
                  media="video/$RepresentationID$/chunk-$$-$Number%05d$.m4s">
                <SegmentTimeline><S t="0" d="4000" r="2" /></SegmentTimeline>
              </SegmentTemplate>
              <Representation id="v-low" bandwidth="500000" width="640" height="360" />
              <Representation id="v-high" bandwidth="2500000" width="1920" height="1080" />
            </AdaptationSet>
            <AdaptationSet contentType="audio" mimeType="audio/mp4">
              <ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011"
                  value="cbcs" cenc:default_KID="\#(audioKeyID)" />
              <Representation id="a-main" bandwidth="128000">
                <BaseURL>audio/</BaseURL>
                <SegmentList>
                  <Initialization sourceURL="init.mp4" range="0-99" />
                  <SegmentURL media="1.m4s" mediaRange="100-199" />
                  <SegmentURL media="2.m4s" />
                </SegmentList>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """#
    }

    private func audioOnlyManifestXML() -> String {
        #"""
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
             xmlns:cenc="urn:mpeg:cenc:2013"
             type="static"
             mediaPresentationDuration="PT8S">
          <BaseURL>media/</BaseURL>
          <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed">
            <cenc:pssh>\#(pssh)</cenc:pssh>
          </ContentProtection>
          <Period duration="PT8S">
            <AdaptationSet contentType="audio" mimeType="audio/mp4">
              <ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011"
                  value="cbcs" cenc:default_KID="\#(audioKeyID)" />
              <Representation id="a-main" bandwidth="128000">
                <BaseURL>audio/</BaseURL>
                <SegmentList>
                  <Initialization sourceURL="init.mp4" range="0-99" />
                  <SegmentURL media="1.m4s" mediaRange="100-199" />
                  <SegmentURL media="2.m4s" />
                </SegmentList>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """#
    }
}

private actor RecordingDASHFetcher: DASHSegmentFetching {
    private var active = 0
    private var maximumActive = 0
    private var calls = 0
    private var ranges: [ByteRange] = []
    private var maximumByteLimits = Set<Int>()

    func fetch(
        to destinationURL: URL,
        url: URL,
        referer: URL?,
        byteRange: ByteRange?,
        maximumBytes: Int
    ) async throws -> Int64 {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if let byteRange { ranges.append(byteRange) }
        maximumByteLimits.insert(maximumBytes)
        try await Task.sleep(nanoseconds: 5_000_000)
        let name: String
        switch url.lastPathComponent {
        case "init.mp4":
            name = url.path.contains("/audio/") ? "audio-init" : "video-init"
        case "chunk-$-00007.m4s": name = "video-7"
        case "chunk-$-00008.m4s": name = "video-8"
        case "chunk-$-00009.m4s": name = "video-9"
        case "1.m4s": name = "audio-1"
        case "2.m4s": name = "audio-2"
        default: throw URLError(.badURL)
        }
        let data: Data
        if name == "video-init" {
            data = SyntheticEncryptedFMP4.initialization(
                keyID: "11111111-2222-3333-4444-555555555555",
                tencVersion: 0,
                mediaType: .video
            )
        } else if name == "audio-init" {
            data = SyntheticEncryptedFMP4.initialization(
                keyID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                tencVersion: 1,
                mediaType: .audio
            )
        } else {
            data = SyntheticEncryptedFMP4.fragment(payload: Data(name.utf8))
        }
        guard data.count <= maximumBytes else {
            throw WidevineDASHProviderError.segmentTooLarge
        }
        try data.write(to: destinationURL, options: .atomic)
        return Int64(data.count)
    }

    func maximumConcurrentRequests() -> Int { maximumActive }
    func requestedRanges() -> [ByteRange] { ranges.sorted { $0.offset < $1.offset } }
    func requestedMaximumBytes() -> Set<Int> { maximumByteLimits }
    func callCount() -> Int { calls }
}

private enum SyntheticEncryptedFMP4 {
    enum MediaType: Equatable {
        case video
        case audio
    }

    static func initialization(
        keyID: String,
        tencVersion: UInt8,
        mediaType: MediaType,
        useExtendedContainerSize: Bool = false
    ) -> Data {
        precondition(tencVersion == 0 || tencVersion == 1)
        var tencPayload = Data([tencVersion, 0, 0, 0, 0])
        tencPayload.append(tencVersion == 0 ? 0 : 0x19)
        tencPayload.append(contentsOf: [1, 8])
        tencPayload.append(keyBytes(keyID))
        let tenc = box(type: "tenc", payload: tencPayload)
        let schi = box(type: "schi", payload: tenc)
        let sinf = box(type: "sinf", payload: schi)
        let sampleHeaderSize = mediaType == .video ? 78 : 28
        let sampleEntry = box(
            type: mediaType == .video ? "encv" : "enca",
            payload: Data(repeating: 0, count: sampleHeaderSize) + sinf
        )
        let stsdPayload = Data(repeating: 0, count: 4) + uint32(1) + sampleEntry
        let stsd = box(type: "stsd", payload: stsdPayload)
        let stbl = box(type: "stbl", payload: stsd)
        let minf = box(type: "minf", payload: stbl)
        let mdia = box(type: "mdia", payload: minf)
        let trak = box(type: "trak", payload: mdia)
        let moov = box(
            type: "moov",
            payload: trak,
            extendedSize: useExtendedContainerSize
        )
        return box(type: "ftyp", payload: Data("isom0000".utf8)) + moov
    }

    static func fragment(
        payload: Data,
        seigKeyID: String? = nil,
        includeSampleToGroup: Bool = false,
        useExtendedContainerSize: Bool = false,
        includePIFFUUID: Bool = false
    ) -> Data {
        fragmentPrefix(
            seigKeyID: seigKeyID,
            includeSampleToGroup: includeSampleToGroup,
            useExtendedContainerSize: useExtendedContainerSize,
            includePIFFUUID: includePIFFUUID
        ) + box(type: "mdat", payload: payload)
    }

    static func fragmentPrefix(
        seigKeyID: String? = nil,
        includeSampleToGroup: Bool = false,
        useExtendedContainerSize: Bool = false,
        includePIFFUUID: Bool = false
    ) -> Data {
        var trafPayload = box(type: "tfhd", payload: Data())
        if let seigKeyID {
            var entry = Data([0, 0, 1, 8])
            entry.append(keyBytes(seigKeyID))
            let sgpdPayload = Data([1, 0, 0, 0])
                + Data("seig".utf8)
                + uint32(UInt32(entry.count))
                + uint32(1)
                + entry
            trafPayload.append(box(type: "sgpd", payload: sgpdPayload))
        }
        if includeSampleToGroup {
            let sbgpPayload = Data([0, 0, 0, 0])
                + Data("seig".utf8)
                + uint32(1)
                + uint32(1)
                + uint32(1)
            trafPayload.append(box(type: "sbgp", payload: sbgpPayload))
        }
        if includePIFFUUID {
            trafPayload.append(
                box(type: "uuid", payload: Data(repeating: 0xA5, count: 16))
            )
        }
        let traf = box(
            type: "traf",
            payload: trafPayload,
            extendedSize: useExtendedContainerSize
        )
        return box(
            type: "moof",
            payload: traf,
            extendedSize: useExtendedContainerSize
        )
    }

    static func openEndedMDATHeader() -> Data {
        uint32(0) + Data("mdat".utf8)
    }

    static func fragmentWithUnrelatedSampleGroups() -> Data {
        let sgpd = box(
            type: "sgpd",
            payload: Data([0, 0, 0, 0]) + Data("roll".utf8) + uint32(0)
        )
        let sbgp = box(
            type: "sbgp",
            payload: Data([0, 0, 0, 0]) + Data("roll".utf8) + uint32(0)
        )
        let traf = box(type: "traf", payload: sgpd + sbgp)
        return box(type: "moof", payload: traf) + box(type: "mdat", payload: Data([0]))
    }

    private static func box(
        type: String,
        payload: Data,
        extendedSize: Bool = false
    ) -> Data {
        precondition(type.utf8.count == 4)
        if extendedSize {
            return uint32(1)
                + Data(type.utf8)
                + uint64(UInt64(16 + payload.count))
                + payload
        }
        return uint32(UInt32(8 + payload.count)) + Data(type.utf8) + payload
    }

    private static func keyBytes(_ keyID: String) -> Data {
        var uuid = UUID(uuidString: keyID)!.uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ])
    }

    private static func uint64(_ value: UInt64) -> Data {
        Data([
            UInt8(truncatingIfNeeded: value >> 56),
            UInt8(truncatingIfNeeded: value >> 48),
            UInt8(truncatingIfNeeded: value >> 40),
            UInt8(truncatingIfNeeded: value >> 32),
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ])
    }
}

private actor RecordingKeyAcquirer: WidevineKeyAcquiring {
    nonisolated let isConfigured = true
    private let keys: [WidevineContentKey]
    private var calls = 0
    private var lastExpectedKeyIDs: Set<String> = []
    private var lastInitDataCount = 0

    init(keys: [WidevineContentKey]) {
        self.keys = keys
    }

    func acquireKeys(
        initData: [Data],
        expectedKeyIDs: Set<String>,
        licenseConfiguration: WidevineLicenseConfiguration,
        wvdData: Data
    ) async throws -> [WidevineContentKey] {
        calls += 1
        lastExpectedKeyIDs = expectedKeyIDs
        lastInitDataCount = initData.count
        return keys
    }

    func snapshot() -> (expectedKeyIDs: Set<String>, initDataCount: Int) {
        (lastExpectedKeyIDs, lastInitDataCount)
    }

    func callCount() -> Int { calls }
}

private actor RecordingMediaComposer: WidevineMediaComposing {
    nonisolated let isConfigured = true
    private let outputData: Data
    private var videoData: Data?
    private var audioData: Data?
    private var videoKey: Data?
    private var audioKey: Data?
    private var videoScheme: DASHCommonEncryptionScheme?
    private var audioScheme: DASHCommonEncryptionScheme?

    init(outputData: Data = minimalMP4Data()) {
        self.outputData = outputData
    }

    func decryptAndMux(
        video: WidevineEncryptedTrackInput?,
        audio: WidevineEncryptedTrackInput?,
        outputURL: URL
    ) async throws {
        videoData = try video.map { try Data(contentsOf: $0.encryptedFileURL) }
        audioData = try audio.map { try Data(contentsOf: $0.encryptedFileURL) }
        videoKey = video?.keyData
        audioKey = audio?.keyData
        videoScheme = video?.scheme
        audioScheme = audio?.scheme
        try outputData.write(to: outputURL, options: .atomic)
    }

    func snapshot() -> (
        videoData: Data?,
        audioData: Data?,
        videoKey: Data?,
        audioKey: Data?,
        videoScheme: DASHCommonEncryptionScheme?,
        audioScheme: DASHCommonEncryptionScheme?
    ) {
        (videoData, audioData, videoKey, audioKey, videoScheme, audioScheme)
    }
}

private func minimalMP4Data() -> Data {
    Data([
        0x00, 0x00, 0x00, 0x18,
        0x66, 0x74, 0x79, 0x70,
        0x69, 0x73, 0x6F, 0x6D,
        0x00, 0x00, 0x02, 0x00,
        0x69, 0x73, 0x6F, 0x6D,
        0x69, 0x73, 0x6F, 0x32
    ])
}

private func minimalPCM16WAVData() -> Data {
    var data = Data("RIFF".utf8)
    data.append(contentsOf: [38, 0, 0, 0])
    data.append(Data("WAVE".utf8))
    data.append(Data("fmt ".utf8))
    data.append(contentsOf: [16, 0, 0, 0])
    data.append(contentsOf: [1, 0])       // PCM
    data.append(contentsOf: [1, 0])       // mono
    data.append(contentsOf: [0x40, 0x1F, 0, 0]) // 8 kHz
    data.append(contentsOf: [0x80, 0x3E, 0, 0]) // 16 kB/s
    data.append(contentsOf: [2, 0])       // block align
    data.append(contentsOf: [16, 0])      // signed 16-bit little-endian
    data.append(Data("data".utf8))
    data.append(contentsOf: [2, 0, 0, 0])
    data.append(contentsOf: [0, 0])
    return data
}
