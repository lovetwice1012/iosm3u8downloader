import Foundation

final class HLSDownloadService: @unchecked Sendable {
    private let sourceResolver: SourceResolver
    private let planBuilder: DownloadPlanBuilder
    private let segmentDownloader: SegmentDownloader
    private let composer = MP4Composer()
    private let fileStore = FileStore()

    init() {
        let client = HTTPClient()
        let resolver = SourceResolver(client: client)
        sourceResolver = resolver
        planBuilder = DownloadPlanBuilder(resolver: resolver)
        segmentDownloader = SegmentDownloader(client: client)
    }

    func download(input: String, progress: @escaping ProgressHandler) async throws -> DownloadResult {
        await progress(DownloadProgress(phase: .resolving, completedItems: 0, totalItems: 0))
        let jobDirectory = try fileStore.makeJobDirectory()
        var temporaryOutput: URL?

        do {
            let document = try await sourceResolver.resolve(input: input)
            let plan = try await planBuilder.build(from: document)
            try Task.checkCancellation()

            await progress(
                DownloadProgress(phase: .downloading, completedItems: 0, totalItems: plan.segmentCount)
            )
            let main = try await segmentDownloader.download(
                playlist: plan.main,
                prefix: "main",
                directory: jobDirectory,
                completedBefore: 0,
                totalSegments: plan.segmentCount,
                progress: progress
            )

            let audio: [DownloadedSegment]?
            if let audioPlaylist = plan.audio {
                audio = try await segmentDownloader.download(
                    playlist: audioPlaylist,
                    prefix: "audio",
                    directory: jobDirectory,
                    completedBefore: plan.main.segments.count,
                    totalSegments: plan.segmentCount,
                    progress: progress
                )
            } else {
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
}

