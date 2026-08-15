import Foundation

protocol HLSDownloadServicing: Sendable {
    func discover(input: String) async throws -> HLSDiscoveryResult
    @MainActor
    func preparePlaybackCapture(input: String) async throws -> PlaybackCaptureSession
    @MainActor
    func finishPlaybackCapture(_ session: PlaybackCaptureSession) async -> [HLSCandidate]
    func download(
        candidate: HLSCandidate,
        progress: @escaping ProgressHandler
    ) async throws -> DownloadResult
    func thumbnailData(for candidate: HLSCandidate) async -> Data?
    func hasWidevineCredential() -> Bool
    func importWidevineCredential(_ data: Data) throws -> WVDFileMetadata
    func deleteWidevineCredential() throws
    func isWidevineProcessingConfigured() -> Bool
    func resetDiagnosticLog()
    func diagnosticLogText() -> String
}

private actor SegmentProgressTracker {
    private var completedItems = 0
    private let totalItems: Int
    private let progress: ProgressHandler

    init(totalItems: Int, progress: @escaping ProgressHandler) {
        self.totalItems = totalItems
        self.progress = progress
    }

    func segmentCompleted() async {
        completedItems += 1
        await progress(
            DownloadProgress(
                phase: .downloading,
                completedItems: completedItems,
                totalItems: totalItems
            )
        )
    }
}

final class HLSDownloadService: HLSDownloadServicing, @unchecked Sendable {
    private let client: HTTPClient
    private let sourceResolver: SourceResolver
    private let planBuilder: DownloadPlanBuilder
    private let segmentDownloader: SegmentDownloader
    private let composer = MP4Composer()
    private let sampleAESComposer = SampleAESFFmpegComposer()
    private let fileStore = FileStore()
    private let diagnostics: DiagnosticLogStore
    private let widevineCredentialStore: any WidevineCredentialStoring
    private let widevineProcessor: any WidevineProcessingProviding

    @MainActor
    convenience init() {
        let configuration = URLSessionConfiguration.ephemeral
        let client = HTTPClient(configuration: configuration)
        let diagnostics = DiagnosticLogStore()
        let widevineProcessor = WidevineDASHDownloadProvider(
            segmentFetcher: HTTPDASHSegmentFetcher(client: client),
            keyAcquirer: WidevineL3KeyAcquirer(transport: client),
            mediaComposer: FFmpegWidevineMediaComposer()
        )
        self.init(
            client: client,
            dynamicInspector: WebPageInspector(diagnosticSink: diagnostics.sink),
            diagnostics: diagnostics,
            widevineCredentialStore: KeychainWidevineCredentialStore(),
            widevineProcessor: widevineProcessor
        )
    }

    init(
        client: HTTPClient,
        dynamicInspector: (any DynamicPageInspecting)? = nil,
        diagnostics: DiagnosticLogStore = DiagnosticLogStore(),
        widevineCredentialStore: any WidevineCredentialStoring = KeychainWidevineCredentialStore(),
        widevineProcessor: any WidevineProcessingProviding = UnconfiguredWidevineProcessingProvider()
    ) {
        self.client = client
        self.diagnostics = diagnostics
        self.widevineCredentialStore = widevineCredentialStore
        self.widevineProcessor = DomainRestrictedWidevineProcessingProvider(base: widevineProcessor)
        let resolver = SourceResolver(
            client: client,
            dynamicInspector: dynamicInspector,
            diagnosticSink: diagnostics.sink
        )
        sourceResolver = resolver
        planBuilder = DownloadPlanBuilder(resolver: resolver)
        segmentDownloader = SegmentDownloader(client: client)
    }

    func discover(input: String) async throws -> HLSDiscoveryResult {
        do {
            let result = try await sourceResolver.discover(input: input)
            diagnostics.record(
                "service",
                "discovery completed candidates=\(result.candidates.count) direct=\(result.isDirectPlaylist)"
            )
            return result
        } catch is CancellationError {
            diagnostics.record("service", "discovery cancelled")
            throw HLSError.cancelled
        } catch let error as HLSError {
            if case .cancelled = error {
                diagnostics.record("service", "discovery cancelled")
            } else {
                diagnostics.record("service", "discovery failed error=\(DiagnosticPrivacy.errorCode(error))")
            }
            throw error
        } catch {
            diagnostics.record("service", "discovery failed error=\(DiagnosticPrivacy.errorCode(error))")
            throw error
        }
    }

    func resetDiagnosticLog() {
        diagnostics.reset()
        diagnostics.record("session", "started")
    }

    func diagnosticLogText() -> String {
        diagnostics.renderedText()
    }

    func hasWidevineCredential() -> Bool {
        (try? widevineCredentialStore.load()) != nil
    }

    func importWidevineCredential(_ data: Data) throws -> WVDFileMetadata {
        let metadata = try WVDFileValidator().validate(data)
        try widevineCredentialStore.save(data)
        diagnostics.record("widevine", "L3 credential imported version=\(metadata.version)")
        return metadata
    }

    func deleteWidevineCredential() throws {
        try widevineCredentialStore.delete()
        diagnostics.record("widevine", "L3 credential removed")
    }

    func isWidevineProcessingConfigured() -> Bool {
        widevineProcessor.isConfigured
    }

    @MainActor
    func preparePlaybackCapture(input: String) async throws -> PlaybackCaptureSession {
        let url = try URIResolver.normalizeInput(input)
        guard url.host != nil, url.user == nil, url.password == nil else {
            throw HLSError.invalidURL
        }
        diagnostics.record(
            "playback",
            "interactive inspection preparing \(DiagnosticPrivacy.urlSummary(url))"
        )
        let session = PlaybackCaptureSession(
            url: url,
            seedCookies: client.cookies(for: url),
            diagnosticSink: diagnostics.sink
        )
        await session.start()
        return session
    }

    @MainActor
    func finishPlaybackCapture(_ session: PlaybackCaptureSession) async -> [HLSCandidate] {
        let inspection = await session.snapshotAndStop()
        let candidates = await sourceResolver.importDynamicInspection(
            inspection,
            rootURL: session.rootURL
        )
        diagnostics.record(
            "playback",
            "interactive inspection finished references=\(inspection.media.count) candidates=\(candidates.count)"
        )
        return candidates
    }

    func download(input: String, progress: @escaping ProgressHandler) async throws -> DownloadResult {
        await progress(DownloadProgress(phase: .resolving, completedItems: 0, totalItems: 0))
        let discovery = try await sourceResolver.discover(input: input)
        guard let candidate = discovery.candidates.first else {
            throw HLSError.noPlaylistFound
        }
        return try await download(candidate: candidate, progress: progress)
    }

    func download(
        candidate: HLSCandidate,
        progress: @escaping ProgressHandler
    ) async throws -> DownloadResult {
        diagnostics.record(
            "service",
            "candidate selected origin=\(candidate.origin.rawValue) depth=\(candidate.iframeDepth) \(DiagnosticPrivacy.urlSummary(candidate.playlistURL))"
        )
        await progress(DownloadProgress(phase: .resolving, completedItems: 0, totalItems: 0))
        if candidate.kind == .widevineDASH {
            guard isDownloadableWidevineDomain(candidate.playlistURL) else {
                diagnostics.record("widevine", "download start rejected by domain policy")
                throw WidevineProcessingError.domainNotAllowed
            }
            guard widevineProcessor.isConfigured else {
                diagnostics.record("widevine", "download start rejected because processor is unconfigured")
                throw WidevineProcessingError.unconfigured
            }
            guard let document = candidate.document else {
                diagnostics.record("widevine", "download start rejected because validated MPD is missing")
                throw HLSError.invalidPlaylist("Widevine MPDを再検証できません")
            }
            return try await downloadWidevineWithBackgroundExecution(
                document: document,
                playbackContext: candidate.widevinePlaybackContext,
                progress: progress
            )
        }

        let document: PlaylistDocument
        do {
            if let discoveredDocument = candidate.document {
                document = discoveredDocument
            } else {
                document = try await sourceResolver.load(
                    candidate.request,
                    referer: candidate.requestReferer
                )
            }
        } catch {
            let code = DiagnosticPrivacy.errorCode(error)
            diagnostics.record(
                "download",
                code == "cancelled" ? "cancelled before planning" : "playlist validation failed error=\(code)"
            )
            throw error
        }
        return try await downloadWithBackgroundExecution(
            document: document,
            requestedPlaylistURL: candidate.request.primary,
            progress: progress
        )
    }

    func thumbnailData(for candidate: HLSCandidate) async -> Data? {
        guard let thumbnailURL = candidate.thumbnailURL,
              AutomaticNavigationPolicy.isAllowedFrameNavigation(
                from: candidate.pageURL,
                to: thumbnailURL
              ) else { return nil }
        do {
            let payload = try await client.fetchLimited(
                thumbnailURL,
                referer: candidate.pageURL,
                maximumBytes: 8 * 1_024 * 1_024
            )
            guard !payload.data.isEmpty,
                  payload.data.count <= 8 * 1_024 * 1_024,
                  (payload.mimeType?.lowercased().hasPrefix("image/") == true
                    || Self.hasImageSignature(payload.data)) else {
                return nil
            }
            return payload.data
        } catch {
            return nil
        }
    }

    private func downloadWidevineWithBackgroundExecution(
        document: PlaylistDocument,
        playbackContext: WidevinePlaybackContext?,
        progress: @escaping ProgressHandler
    ) async throws -> DownloadResult {
        try await BackgroundExecutionCoordinator.shared.run(
            title: "Widevine動画を保存",
            subtitle: "ダウンロードを準備中",
            diagnosticSink: diagnostics.sink
        ) { [self] backgroundProgress in
            await backgroundProgress.report(
                DownloadProgress(phase: .resolving, completedItems: 0, totalItems: 0)
            )
            return try await downloadWidevine(
                document: document,
                playbackContext: playbackContext
            ) { update in
                await backgroundProgress.report(update)
                await progress(update)
            }
        }
    }

    private func downloadWidevine(
        document: PlaylistDocument,
        playbackContext: WidevinePlaybackContext?,
        progress: @escaping ProgressHandler
    ) async throws -> DownloadResult {
        guard isDownloadableWidevineDomain(document.effectiveURL) else {
            throw WidevineProcessingError.domainNotAllowed
        }
        guard let wvdData = try widevineCredentialStore.load() else {
            throw WidevineProcessingError.credentialMissing
        }

        let manifestData = Data(document.text.utf8)
        let manifest = try DASHManifestParser.parse(
            data: manifestData,
            effectiveURL: document.effectiveURL
        )
        guard manifest.isWidevine else {
            throw HLSError.invalidPlaylist("Widevine ContentProtectionを確認できません")
        }
        // An explicit Widevine Laurl is authoritative. Playback traffic is a
        // fallback only when it was correlated with an EME message in the same
        // frame; URL-keyword heuristics are never used to select an endpoint.
        let observedLicenseURL = playbackContext?.isHighConfidence == true
            ? playbackContext?.licenseServerURL
            : nil
        let licenseURL = manifest.widevineLicenseURLs.first ?? observedLicenseURL
        guard let licenseURL,
              isDownloadableWidevineDomain(licenseURL) else {
            throw WidevineProcessingError.licenseServerMissing
        }
        let observedRequestMetadata = playbackContext?.isHighConfidence == true
            && playbackContext?.licenseServerURL == licenseURL
            ? playbackContext?.requestMetadata
            : nil

        try Task.checkCancellation()
        await progress(DownloadProgress(phase: .downloading, completedItems: 0, totalItems: 0))
        diagnostics.record(
            "widevine",
            "processing started schemes=\(manifest.encryptionSchemes.count) tracks=\(manifest.adaptationSets.count)"
        )

        // 復号済みファイル生成の直前にも、共通ポリシーを必ず再確認する。
        guard isDownloadableWidevineDomain(document.effectiveURL) else {
            throw WidevineProcessingError.domainNotAllowed
        }
        let processed = try await widevineProcessor.process(
            manifest: WidevineManifestDocument(
                sourceURL: document.effectiveURL,
                data: manifestData
            ),
            licenseConfiguration: WidevineLicenseConfiguration(
                serverURL: licenseURL,
                refererURL: playbackContext?.pageURL ?? document.effectiveURL,
                observedRequestMetadata: observedRequestMetadata
            ),
            wvdData: wvdData
        )
        let sourceURL = processed.mediaFileURL
        defer {
            if sourceURL.isFileURL {
                try? FileManager.default.removeItem(at: sourceURL)
            }
        }

        try Task.checkCancellation()
        await progress(DownloadProgress(phase: .composing, completedItems: 0, totalItems: 0))
        guard sourceURL.isFileURL else {
            throw WidevineProcessingError.invalidOutput
        }
        let values = try sourceURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0,
              WidevineMediaOutputValidator.isValid(
                sourceURL,
                format: processed.outputFormat
              ) else {
            throw WidevineProcessingError.invalidOutput
        }

        let locations = try fileStore.outputLocations(
            for: document.effectiveURL,
            format: processed.outputFormat
        )
        try? FileManager.default.removeItem(at: locations.temporary)
        do {
            try await fileStore.copyProtectedFile(
                from: sourceURL,
                to: locations.temporary
            )
            try Task.checkCancellation()
            guard WidevineMediaOutputValidator.isValid(
                locations.temporary,
                format: processed.outputFormat
            ) else {
                throw WidevineProcessingError.invalidOutput
            }
            // 保存へ進む直前の最終チェック。許可host比較はこの共通関数だけが行う。
            guard isDownloadableWidevineDomain(document.effectiveURL) else {
                throw WidevineProcessingError.domainNotAllowed
            }
            try FileManager.default.moveItem(at: locations.temporary, to: locations.final)
        } catch {
            try? FileManager.default.removeItem(at: locations.temporary)
            throw error
        }

        await progress(DownloadProgress(phase: .completed, completedItems: 1, totalItems: 1))
        diagnostics.record(
            "widevine",
            "processing completed format=\(processed.outputFormat.rawValue)"
        )
        return DownloadResult(
            outputURL: locations.final,
            sourceURL: document.effectiveURL,
            segmentCount: 0
        )
    }

    private func downloadWithBackgroundExecution(
        document: PlaylistDocument,
        requestedPlaylistURL: URL,
        progress: @escaping ProgressHandler
    ) async throws -> DownloadResult {
        try await BackgroundExecutionCoordinator.shared.run(
            title: "HLS動画を保存",
            subtitle: "ダウンロードを準備中",
            diagnosticSink: diagnostics.sink
        ) { [self] backgroundProgress in
            await backgroundProgress.report(
                DownloadProgress(phase: .resolving, completedItems: 0, totalItems: 0)
            )
            return try await download(
                document: document,
                requestedPlaylistURL: requestedPlaylistURL
            ) { update in
                await backgroundProgress.report(update)
                await progress(update)
            }
        }
    }

    private func download(
        document: PlaylistDocument,
        requestedPlaylistURL: URL,
        progress: @escaping ProgressHandler
    ) async throws -> DownloadResult {
        let jobDirectory = try fileStore.makeJobDirectory()
        var temporaryOutput: URL?

        do {
            let preparedPlan = try await planBuilder.build(
                from: document,
                requestedURL: requestedPlaylistURL
            )
            let plan = preparedPlan.plan
            try Task.checkCancellation()
            diagnostics.record(
                "download",
                "plan ready mainSegments=\(plan.main.segments.count) audioSegments=\(plan.audio?.segments.count ?? 0) total=\(plan.segmentCount) \(DiagnosticPrivacy.urlSummary(plan.sourceURL))"
            )

            if preparedPlan.containsSampleAES {
                guard !preparedPlan.containsAES128 else {
                    throw HLSError.drmUnsupported("mixed AES-128 and SAMPLE-AES playlists")
                }
                return try await downloadSampleAES(
                    preparedPlan,
                    jobDirectory: jobDirectory,
                    progress: progress
                )
            }

            await progress(
                DownloadProgress(phase: .downloading, completedItems: 0, totalItems: plan.segmentCount)
            )
            let progressTracker = SegmentProgressTracker(
                totalItems: plan.segmentCount,
                progress: progress
            )
            let main: [DownloadedSegment]
            let audio: [DownloadedSegment]?
            if let audioPlaylist = plan.audio {
                async let mainDownload = segmentDownloader.download(
                    playlist: plan.main,
                    prefix: "main",
                    directory: jobDirectory,
                    completedBefore: 0,
                    totalSegments: plan.segmentCount,
                    progress: { _ in await progressTracker.segmentCompleted() }
                )
                async let audioDownload = segmentDownloader.download(
                    playlist: audioPlaylist,
                    prefix: "audio",
                    directory: jobDirectory,
                    completedBefore: 0,
                    totalSegments: plan.segmentCount,
                    progress: { _ in await progressTracker.segmentCompleted() }
                )
                let downloads = try await (mainDownload, audioDownload)
                main = downloads.0
                audio = downloads.1
            } else {
                main = try await segmentDownloader.download(
                    playlist: plan.main,
                    prefix: "main",
                    directory: jobDirectory,
                    completedBefore: 0,
                    totalSegments: plan.segmentCount,
                    progress: { _ in await progressTracker.segmentCompleted() }
                )
                audio = nil
            }

            try Task.checkCancellation()
            await progress(DownloadProgress(phase: .composing, completedItems: 0, totalItems: 0))
            let outputFormat = try await composer.outputFormat(
                main: main,
                externalAudio: audio
            )
            diagnostics.record(
                "compose",
                "started format=\(outputFormat.rawValue) mainFiles=\(main.count) audioFiles=\(audio?.count ?? 0)"
            )
            let locations = try fileStore.outputLocations(
                for: plan.sourceURL,
                format: outputFormat
            )
            temporaryOutput = locations.temporary
            try await composer.compose(
                main: main,
                externalAudio: audio,
                format: outputFormat,
                outputURL: locations.temporary
            )
            try FileManager.default.moveItem(at: locations.temporary, to: locations.final)
            temporaryOutput = nil
            fileStore.removeJobDirectory(jobDirectory)
            await progress(DownloadProgress(phase: .completed, completedItems: 1, totalItems: 1))
            diagnostics.record("download", "completed segments=\(plan.segmentCount)")
            return DownloadResult(
                outputURL: locations.final,
                sourceURL: plan.sourceURL,
                segmentCount: plan.segmentCount
            )
        } catch is CancellationError {
            diagnostics.record("download", "cancelled")
            if let temporaryOutput { try? FileManager.default.removeItem(at: temporaryOutput) }
            fileStore.removeJobDirectory(jobDirectory)
            throw HLSError.cancelled
        } catch let error as HLSError {
            if case .cancelled = error {
                diagnostics.record("download", "cancelled")
            } else {
                diagnostics.record("download", "failed error=\(DiagnosticPrivacy.errorSummary(error))")
            }
            if let temporaryOutput { try? FileManager.default.removeItem(at: temporaryOutput) }
            fileStore.removeJobDirectory(jobDirectory)
            throw error
        } catch {
            diagnostics.record("download", "failed error=\(DiagnosticPrivacy.errorSummary(error))")
            if let temporaryOutput { try? FileManager.default.removeItem(at: temporaryOutput) }
            fileStore.removeJobDirectory(jobDirectory)
            throw error
        }
    }

    private func downloadSampleAES(
        _ prepared: PreparedDownloadPlan,
        jobDirectory: URL,
        progress: @escaping ProgressHandler
    ) async throws -> DownloadResult {
        try prepared.validateSampleAESPermit()
        let plan = prepared.plan
        await progress(
            DownloadProgress(
                phase: .downloading,
                completedItems: 0,
                totalItems: plan.segmentCount
            )
        )
        let progressTracker = SegmentProgressTracker(
            totalItems: plan.segmentCount,
            progress: progress
        )

        let main: DownloadedSampleAESPlaylist
        let audio: DownloadedSampleAESPlaylist?
        if let audioPlaylist = plan.audio,
           let audioRequestedURL = prepared.audioRequestedURL {
            async let mainDownload = segmentDownloader.downloadSampleAESPlaylist(
                playlist: plan.main,
                requestedPlaylistURL: prepared.mainRequestedURL,
                prefix: "main",
                directory: jobDirectory,
                completedBefore: 0,
                totalSegments: plan.segmentCount,
                progress: { _ in await progressTracker.segmentCompleted() }
            )
            async let audioDownload = segmentDownloader.downloadSampleAESPlaylist(
                playlist: audioPlaylist,
                requestedPlaylistURL: audioRequestedURL,
                prefix: "audio",
                directory: jobDirectory,
                completedBefore: 0,
                totalSegments: plan.segmentCount,
                progress: { _ in await progressTracker.segmentCompleted() }
            )
            let downloaded = try await (mainDownload, audioDownload)
            main = downloaded.0
            audio = downloaded.1
        } else {
            main = try await segmentDownloader.downloadSampleAESPlaylist(
                playlist: plan.main,
                requestedPlaylistURL: prepared.mainRequestedURL,
                prefix: "main",
                directory: jobDirectory,
                completedBefore: 0,
                totalSegments: plan.segmentCount,
                progress: { _ in await progressTracker.segmentCompleted() }
            )
            audio = nil
        }

        try Task.checkCancellation()
        try prepared.validateSampleAESPermit()
        await progress(DownloadProgress(phase: .composing, completedItems: 0, totalItems: 0))
        diagnostics.record(
            "compose",
            "SAMPLE-AES started mainSegments=\(plan.main.segments.count) audioSegments=\(plan.audio?.segments.count ?? 0)"
        )
        let decryptedOutput = jobDirectory.appendingPathComponent(
            "sample-aes-decrypted-output.tmp",
            isDirectory: false
        )
        let diagnosticKeys = Array(Set(
            main.diagnosticKeys + (audio?.diagnosticKeys ?? [])
        ))
        let composedFormat = try await sampleAESComposer.compose(
            primaryPlaylistURL: main.playlistURL,
            externalAudioPlaylistURL: audio?.playlistURL,
            diagnosticKeys: diagnosticKeys,
            outputURL: decryptedOutput
        )
        let outputFormat: MediaOutputFormat = composedFormat == .wav ? .wav : .mp4

        try Task.checkCancellation()
        try prepared.validateSampleAESPermit()
        let locations = try fileStore.outputLocations(
            for: plan.sourceURL,
            format: outputFormat
        )
        do {
            try await fileStore.copyProtectedFile(
                from: decryptedOutput,
                to: locations.temporary
            )
            try Task.checkCancellation()
            // The common playlist permit is the final gate before a decrypted
            // artifact becomes a user-visible export.
            try prepared.validateSampleAESPermit()
            try FileManager.default.moveItem(at: locations.temporary, to: locations.final)
        } catch {
            try? FileManager.default.removeItem(at: locations.temporary)
            throw error
        }

        fileStore.removeJobDirectory(jobDirectory)
        await progress(DownloadProgress(phase: .completed, completedItems: 1, totalItems: 1))
        diagnostics.record(
            "download",
            "SAMPLE-AES completed format=\(outputFormat.rawValue) segments=\(plan.segmentCount)"
        )
        return DownloadResult(
            outputURL: locations.final,
            sourceURL: plan.sourceURL,
            segmentCount: plan.segmentCount
        )
    }

    private static func hasImageSignature(_ data: Data) -> Bool {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        if data.starts(with: Array("GIF8".utf8)) { return true }
        if data.count >= 12,
           String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
           String(decoding: data[8..<12], as: UTF8.self) == "WEBP" {
            return true
        }
        if data.count >= 12,
           String(decoding: data[4..<8], as: UTF8.self) == "ftyp" {
            let brand = String(decoding: data[8..<12], as: UTF8.self).lowercased()
            return brand.hasPrefix("hei") || brand.hasPrefix("mif") || brand.hasPrefix("avif")
        }
        return false
    }
}
