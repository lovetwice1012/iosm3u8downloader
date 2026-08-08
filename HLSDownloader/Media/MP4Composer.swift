import AVFoundation
import Foundation

final class MP4Composer: @unchecked Sendable {
    func compose(
        main: [DownloadedSegment],
        externalAudio: [DownloadedSegment]?,
        outputURL: URL
    ) async throws {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw HLSError.noPlayableTracks
        }

        let mainOrigin = try await firstTrackStart(
            in: main,
            preferredMediaTypes: externalAudio == nil ? [.video, .audio] : [.video]
        ) ?? .zero
        let audioOrigin = try await externalAudio.flatMap { segments in
            try await firstTrackStart(in: segments, preferredMediaTypes: [.audio])
        }
        let commonOrigin = earliestTime(mainOrigin, audioOrigin)
        let mainOffset = nonnegativeDifference(mainOrigin, commonOrigin)

        let mainResult = try await append(
            main,
            videoDestination: videoTrack,
            audioDestination: audioTrack,
            includeVideo: true,
            includeAudio: externalAudio == nil,
            initialTimeline: mainOffset
        )

        var hasAudio = mainResult.hasAudio
        if let externalAudio {
            let audioResult = try await append(
                externalAudio,
                videoDestination: videoTrack,
                audioDestination: audioTrack,
                includeVideo: false,
                includeAudio: true,
                initialTimeline: nonnegativeDifference(audioOrigin ?? commonOrigin, commonOrigin)
            )
            hasAudio = audioResult.hasAudio
        }

        guard mainResult.hasVideo || hasAudio else { throw HLSError.noPlayableTracks }
        if externalAudio != nil,
           isPositiveNumeric(mainResult.endTime),
           CMTimeCompare(composition.duration, mainResult.endTime) > 0 {
            composition.removeTimeRange(
                CMTimeRange(
                    start: mainResult.endTime,
                    duration: CMTimeSubtract(composition.duration, mainResult.endTime)
                )
            )
        }
        try await export(composition, to: outputURL)
    }

    private func append(
        _ segments: [DownloadedSegment],
        videoDestination: AVMutableCompositionTrack,
        audioDestination: AVMutableCompositionTrack,
        includeVideo: Bool,
        includeAudio: Bool,
        initialTimeline: CMTime
    ) async throws -> (hasVideo: Bool, hasAudio: Bool, endTime: CMTime) {
        var timeline = initialTimeline
        var hasVideo = false
        var hasAudio = false
        var appliedVideoTransform = false

        for segment in segments.sorted(by: { $0.source.ordinal < $1.source.ordinal }) {
            try Task.checkCancellation()
            let asset = preciseAsset(for: segment.fileURL)
            let assetDuration = try await asset.load(.duration)
            let declaredDuration = CMTime(seconds: segment.source.duration, preferredTimescale: 600)
            let advance = isPositiveNumeric(declaredDuration) ? declaredDuration : assetDuration

            let sourceVideo: AVAssetTrack?
            if includeVideo {
                sourceVideo = try await asset.loadTracks(withMediaType: .video).first
            } else {
                sourceVideo = nil
            }
            let sourceAudio: AVAssetTrack?
            if includeAudio {
                sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
            } else {
                sourceAudio = nil
            }
            let videoRange: CMTimeRange?
            if let sourceVideo {
                videoRange = try await sourceVideo.load(.timeRange)
            } else {
                videoRange = nil
            }
            let audioRange: CMTimeRange?
            if let sourceAudio {
                audioRange = try await sourceAudio.load(.timeRange)
            } else {
                audioRange = nil
            }
            let commonStart = earliestStart(videoRange, audioRange)

            if let sourceVideo, let videoRange {
                let offset = nonnegativeDifference(videoRange.start, commonStart)
                let availableDuration = CMTimeSubtract(advance, offset)
                let range = clipped(videoRange, maximumDuration: availableDuration)
                try videoDestination.insertTimeRange(range, of: sourceVideo, at: CMTimeAdd(timeline, offset))
                if !appliedVideoTransform {
                    videoDestination.preferredTransform = try await sourceVideo.load(.preferredTransform)
                    appliedVideoTransform = true
                }
                hasVideo = true
            }

            if let sourceAudio, let audioRange {
                let offset = nonnegativeDifference(audioRange.start, commonStart)
                let availableDuration = CMTimeSubtract(advance, offset)
                let range = clipped(audioRange, maximumDuration: availableDuration)
                try audioDestination.insertTimeRange(range, of: sourceAudio, at: CMTimeAdd(timeline, offset))
                hasAudio = true
            }

            if isPositiveNumeric(advance) {
                timeline = CMTimeAdd(timeline, advance)
            }
        }
        return (hasVideo, hasAudio, timeline)
    }

    private func firstTrackStart(
        in segments: [DownloadedSegment],
        preferredMediaTypes: [AVMediaType]
    ) async throws -> CMTime? {
        for mediaType in preferredMediaTypes {
            for segment in segments.prefix(3) {
                let asset = preciseAsset(for: segment.fileURL)
                if let track = try await asset.loadTracks(withMediaType: mediaType).first {
                    return try await track.load(.timeRange).start
                }
            }
        }
        return nil
    }

    private func preciseAsset(for url: URL) -> AVURLAsset {
        AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
    }

    private func clipped(_ range: CMTimeRange, maximumDuration: CMTime) -> CMTimeRange {
        guard isPositiveNumeric(maximumDuration),
              isPositiveNumeric(range.duration),
              CMTimeCompare(range.duration, maximumDuration) > 0 else {
            return range
        }
        return CMTimeRange(start: range.start, duration: maximumDuration)
    }

    private func earliestStart(_ lhs: CMTimeRange?, _ rhs: CMTimeRange?) -> CMTime {
        switch (lhs?.start, rhs?.start) {
        case let (left?, right?):
            return CMTimeCompare(left, right) <= 0 ? left : right
        case let (left?, nil):
            return left
        case let (nil, right?):
            return right
        default:
            return .zero
        }
    }

    private func earliestTime(_ lhs: CMTime, _ rhs: CMTime?) -> CMTime {
        guard let rhs else { return lhs }
        return CMTimeCompare(lhs, rhs) <= 0 ? lhs : rhs
    }

    private func nonnegativeDifference(_ time: CMTime, _ baseline: CMTime) -> CMTime {
        let difference = CMTimeSubtract(time, baseline)
        return CMTimeCompare(difference, .zero) > 0 ? difference : .zero
    }

    private func isPositiveNumeric(_ time: CMTime) -> Bool {
        time.isNumeric && CMTimeCompare(time, .zero) > 0
    }

    private func export(_ composition: AVMutableComposition, to outputURL: URL) async throws {
        let presets = [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
        var lastError: Error?

        for preset in presets {
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: outputURL)
            guard let exporter = AVAssetExportSession(asset: composition, presetName: preset),
                  exporter.supportedFileTypes.contains(.mp4) else { continue }

            exporter.outputURL = outputURL
            exporter.outputFileType = .mp4
            exporter.shouldOptimizeForNetworkUse = true

            do {
                try await run(exporter)
                let values = try outputURL.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? 0) > 0 else {
                    throw HLSError.exportFailed("出力が空です")
                }
                return
            } catch {
                if error is CancellationError { throw HLSError.cancelled }
                if let hlsError = error as? HLSError, case .cancelled = hlsError {
                    throw hlsError
                }
                lastError = error
            }
        }

        try? FileManager.default.removeItem(at: outputURL)
        if let hlsError = lastError as? HLSError { throw hlsError }
        if let lastError { throw HLSError.exportFailed(lastError.localizedDescription) }
        throw HLSError.mp4ExportUnsupported
    }

    private func run(_ exporter: AVAssetExportSession) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exporter.exportAsynchronously {
                    switch exporter.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: HLSError.cancelled)
                    case .failed:
                        continuation.resume(
                            throwing: HLSError.exportFailed(exporter.error?.localizedDescription ?? "AVFoundationエラー")
                        )
                    default:
                        continuation.resume(throwing: HLSError.exportFailed("予期しない終了状態です"))
                    }
                }
            }
        } onCancel: {
            exporter.cancelExport()
        }
    }
}
