import Foundation

protocol HLSDownloadServicing: Sendable {
    func discover(input: String) async throws -> HLSDiscoveryResult
    func download(
        candidate: HLSCandidate,
        progress: @escaping ProgressHandler
    ) async throws -> DownloadResult
    func thumbnailData(for candidate: HLSCandidate) async -> Data?
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
    private let fileStore = FileStore()

    @MainActor
    convenience init() {
        let configuration = URLSessionConfiguration.ephemeral
        let client = HTTPClient(configuration: configuration)
        self.init(client: client, dynamicInspector: WebPageInspector())
    }

    init(client: HTTPClient, dynamicInspector: (any DynamicPageInspecting)? = nil) {
        self.client = client
        let resolver = SourceResolver(client: client, dynamicInspector: dynamicInspector)
        sourceResolver = resolver
        planBuilder = DownloadPlanBuilder(resolver: resolver)
        segmentDownloader = SegmentDownloader(client: client)
    }

    func discover(input: String) async throws -> HLSDiscoveryResult {
        try await sourceResolver.discover(input: input)
    }

    func download(input: String, progress: @escaping ProgressHandler) async throws -> DownloadResult {
        await progress(DownloadProgress(phase: .resolving, completedItems: 0, totalItems: 0))
        let document = try await sourceResolver.resolve(input: input)
        return try await download(document: document, progress: progress)
    }

    func download(
        candidate: HLSCandidate,
        progress: @escaping ProgressHandler
    ) async throws -> DownloadResult {
        await progress(DownloadProgress(phase: .resolving, completedItems: 0, totalItems: 0))
        let document: PlaylistDocument
        if let discoveredDocument = candidate.document {
            document = discoveredDocument
        } else {
            document = try await sourceResolver.load(
                candidate.request,
                referer: candidate.requestReferer
            )
        }
        return try await download(document: document, progress: progress)
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

    private func download(
        document: PlaylistDocument,
        progress: @escaping ProgressHandler
    ) async throws -> DownloadResult {
        let jobDirectory = try fileStore.makeJobDirectory()
        var temporaryOutput: URL?

        do {
            let plan = try await planBuilder.build(from: document)
            try Task.checkCancellation()

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
            let locations = try fileStore.outputLocations(for: plan.sourceURL)
            temporaryOutput = locations.temporary
            try await composer.compose(main: main, externalAudio: audio, outputURL: locations.temporary)
            try FileManager.default.moveItem(at: locations.temporary, to: locations.final)
            temporaryOutput = nil
            fileStore.removeJobDirectory(jobDirectory)
            await progress(DownloadProgress(phase: .completed, completedItems: 1, totalItems: 1))
            return DownloadResult(
                outputURL: locations.final,
                sourceURL: plan.sourceURL,
                segmentCount: plan.segmentCount
            )
        } catch is CancellationError {
            if let temporaryOutput { try? FileManager.default.removeItem(at: temporaryOutput) }
            fileStore.removeJobDirectory(jobDirectory)
            throw HLSError.cancelled
        } catch {
            if let temporaryOutput { try? FileManager.default.removeItem(at: temporaryOutput) }
            fileStore.removeJobDirectory(jobDirectory)
            throw error
        }
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
