import AVFoundation
import Foundation

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    private let stateLock = NSLock()
    private var limitExceeded = false

    init(_ session: AVAssetExportSession) {
        self.session = session
    }

    func markOutputLimitExceeded() {
        stateLock.lock()
        limitExceeded = true
        stateLock.unlock()
    }

    func didExceedOutputLimit() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return limitExceeded
    }
}

final class MP4Composer: @unchecked Sendable {
    private let transportStreamRemuxer = TransportStreamRemuxer()
    private let trackProbe = LocalMediaTrackProbe()
    private let audioWAVComposer = FFmpegAudioWAVComposer()

    /// Determines the export format from decoded track metadata. URLs,
    /// extensions and playlist labels never participate in this choice.
    func outputFormat(
        main: [DownloadedSegment],
        externalAudio: [DownloadedSegment]?
    ) async throws -> MediaOutputFormat {
        let mainTracks = try await probeTracks(in: main)
        if mainTracks.contains(.video) {
            if let externalAudio {
                let audioTracks = try await probeTracks(in: externalAudio)
                guard audioTracks.contains(.audio) else { throw HLSError.noPlayableTracks }
            }
            return .mp4
        }

        if let externalAudio {
            let audioTracks = try await probeTracks(in: externalAudio)
            guard audioTracks.contains(.audio) else { throw HLSError.noPlayableTracks }
            return .wav
        }
        guard mainTracks.contains(.audio) else { throw HLSError.noPlayableTracks }
        return .wav
    }

    func compose(
        main: [DownloadedSegment],
        externalAudio: [DownloadedSegment]?,
        format: MediaOutputFormat = .mp4,
        outputURL: URL
    ) async throws {
        guard !main.contains(where: { $0.source.hasDiscontinuity }),
              !(externalAudio?.contains(where: { $0.source.hasDiscontinuity }) ?? false) else {
            throw HLSError.invalidPlaylist("EXT-X-DISCONTINUITYを含むHLSは現在MP4化できません")
        }
        if format == .wav {
            try await composeAudioOnly(externalAudio ?? main, outputURL: outputURL)
            return
        }
        if let externalAudio,
           !main.isEmpty,
           !externalAudio.isEmpty,
           main.allSatisfy({ $0.container == .transportStream }),
           externalAudio.allSatisfy({ $0.container == .transportStream }) {
            try await composeSeparateTransportStreams(
                main: main,
                audio: externalAudio,
                outputURL: outputURL
            )
            return
        }

        let preparedMain = try await prepareTransportStream(
            main,
            label: "main",
            requiresVideo: externalAudio != nil,
            requiresAudio: false
        )
        var preparedAudio: PreparedStream?
        defer {
            preparedMain.removeTemporaryFiles()
            preparedAudio?.removeTemporaryFiles()
        }
        if let externalAudio {
            preparedAudio = try await prepareTransportStream(
                externalAudio,
                label: "audio",
                requiresVideo: false,
                requiresAudio: true
            )
        } else {
            preparedAudio = nil
        }

        if preparedMain.wasRemuxed, externalAudio == nil,
           let remuxed = preparedMain.segments.first {
            try installRemuxedOutput(remuxed.fileURL, at: outputURL)
            return
        }

        try await composeWithConsolidationFallback(
            main: preparedMain.segments,
            externalAudio: preparedAudio?.segments,
            outputURL: outputURL
        )
    }

    private func probeTracks(in segments: [DownloadedSegment]) async throws -> LocalMediaTrackSet {
        let ordered = segments.sorted(by: { $0.source.ordinal < $1.source.ordinal })
        guard !ordered.isEmpty else { throw HLSError.noPlayableTracks }
        let joined = try consolidate(ordered, label: "track-probe")
        defer {
            if let joined { try? FileManager.default.removeItem(at: joined.temporaryURL) }
        }
        if let joined {
            return try await trackProbe.probe(
                inputURL: joined.segment.fileURL,
                input: .mediaFile()
            )
        }

        var combined: LocalMediaTrackSet = []
        var lastError: Error?
        // A positive video finding may stop early. Proving audio-only must scan
        // every segment so a later video period is never silently discarded.
        for segment in ordered {
            do {
                let tracks = try await trackProbe.probe(
                    inputURL: segment.fileURL,
                    input: .mediaFile()
                )
                combined.formUnion(tracks)
                if combined.contains(.video) { break }
            } catch is CancellationError {
                throw HLSError.cancelled
            } catch let error as HLSError {
                if case .cancelled = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
        }
        if !combined.isEmpty { return combined }
        if let hlsError = lastError as? HLSError { throw hlsError }
        if let lastError {
            throw HLSError.mediaOpenFailed(
                stream: "main",
                number: 1,
                container: segments.first?.container.rawValue ?? "unknown",
                byteCount: segments.first?.byteCount ?? 0,
                detail: lastError.localizedDescription
            )
        }
        throw HLSError.noPlayableTracks
    }

    private func composeAudioOnly(
        _ segments: [DownloadedSegment],
        outputURL: URL
    ) async throws {
        let ordered = segments.sorted(by: { $0.source.ordinal < $1.source.ordinal })
        guard !ordered.isEmpty else { throw HLSError.noPlayableTracks }
        let joined = try consolidate(ordered, label: "audio-wav")
        defer {
            if let joined { try? FileManager.default.removeItem(at: joined.temporaryURL) }
        }
        guard ordered.count == 1 || joined != nil else {
            throw HLSError.invalidPlaylist("audio segments could not be consolidated without truncation")
        }
        try await audioWAVComposer.compose(
            inputURL: joined?.segment.fileURL ?? ordered[0].fileURL,
            outputURL: outputURL
        )
    }

    private func composeWithConsolidationFallback(
        main: [DownloadedSegment],
        externalAudio: [DownloadedSegment]?,
        outputURL: URL
    ) async throws {
        do {
            try await composeIndividually(main: main, externalAudio: externalAudio, outputURL: outputURL)
        } catch {
            guard shouldRetryWithConsolidatedMedia(error) else {
                throw error
            }
            let joinedMain = try consolidate(main, label: "main")
            defer {
                if let joinedMain {
                    try? FileManager.default.removeItem(at: joinedMain.temporaryURL)
                }
            }

            let joinedAudio: ConsolidatedInput?
            if let externalAudio {
                joinedAudio = try consolidate(externalAudio, label: "audio")
            } else {
                joinedAudio = nil
            }
            defer {
                if let joinedAudio {
                    try? FileManager.default.removeItem(at: joinedAudio.temporaryURL)
                }
            }
            guard joinedMain != nil || joinedAudio != nil else { throw error }
            try await composeIndividually(
                main: joinedMain.map { [$0.segment] } ?? main,
                externalAudio: joinedAudio.map { [$0.segment] } ?? externalAudio,
                outputURL: outputURL
            )
        }
    }

    private struct PreparedStream {
        let segments: [DownloadedSegment]
        let temporaryURLs: [URL]
        let wasRemuxed: Bool

        func removeTemporaryFiles() {
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func composeSeparateTransportStreams(
        main: [DownloadedSegment],
        audio: [DownloadedSegment],
        outputURL: URL
    ) async throws {
        let orderedMain = main.sorted(by: { $0.source.ordinal < $1.source.ordinal })
        let orderedAudio = audio.sorted(by: { $0.source.ordinal < $1.source.ordinal })
        let joinedMain = try consolidate(orderedMain, label: "main-ts")
        defer {
            if let joinedMain {
                try? FileManager.default.removeItem(at: joinedMain.temporaryURL)
            }
        }
        let joinedAudio = try consolidate(orderedAudio, label: "audio-ts")
        defer {
            if let joinedAudio {
                try? FileManager.default.removeItem(at: joinedAudio.temporaryURL)
            }
        }
        let mainInput = joinedMain?.segment ?? orderedMain[0]
        let audioInput = joinedAudio?.segment ?? orderedAudio[0]
        let remuxedURL = mainInput.fileURL.deletingLastPathComponent().appendingPathComponent(
            "combined-remuxed-\(UUID().uuidString).mp4",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: remuxedURL) }

        try await transportStreamRemuxer.remux(
            inputURL: mainInput.fileURL,
            audioInputURL: audioInput.fileURL,
            outputURL: remuxedURL
        )
        try await validateRemuxedAsset(
            at: remuxedURL,
            requiresVideo: true,
            requiresAudio: true
        )
        try installRemuxedOutput(remuxedURL, at: outputURL)
    }

    private func prepareTransportStream(
        _ segments: [DownloadedSegment],
        label: String,
        requiresVideo: Bool,
        requiresAudio: Bool
    ) async throws -> PreparedStream {
        let ordered = segments.sorted(by: { $0.source.ordinal < $1.source.ordinal })
        guard !ordered.isEmpty,
              ordered.allSatisfy({ $0.container == .transportStream }) else {
            return PreparedStream(segments: segments, temporaryURLs: [], wasRemuxed: false)
        }

        var temporaryURLs: [URL] = []
        let inputSegment: DownloadedSegment
        if ordered.count > 1 {
            guard let joined = try consolidate(ordered, label: "\(label)-ts") else {
                return PreparedStream(segments: segments, temporaryURLs: [], wasRemuxed: false)
            }
            inputSegment = joined.segment
            temporaryURLs.append(joined.temporaryURL)
        } else {
            inputSegment = ordered[0]
        }

        let outputURL = inputSegment.fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(label)-remuxed-\(UUID().uuidString).mp4",
            isDirectory: false
        )
        temporaryURLs.append(outputURL)

        do {
            try await transportStreamRemuxer.remux(
                inputURL: inputSegment.fileURL,
                outputURL: outputURL
            )
            try await validateRemuxedAsset(
                at: outputURL,
                requiresVideo: requiresVideo,
                requiresAudio: requiresAudio
            )
            let values = try outputURL.resourceValues(forKeys: [.fileSizeKey])
            let first = ordered[0]
            let source = MediaSegment(
                ordinal: 0,
                mediaSequence: first.source.mediaSequence,
                duration: ordered.reduce(0.0) { $0 + $1.source.duration },
                url: first.source.url,
                byteRange: nil,
                encryption: nil,
                initializationMap: nil,
                hasDiscontinuity: false
            )
            let remuxed = DownloadedSegment(
                source: source,
                fileURL: outputURL,
                container: .isoBaseMedia,
                byteCount: values.fileSize ?? 0,
                initializationDataLength: 0
            )
            return PreparedStream(
                segments: [remuxed],
                temporaryURLs: temporaryURLs,
                wasRemuxed: true
            )
        } catch {
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    private func validateRemuxedAsset(
        at url: URL,
        requiresVideo: Bool,
        requiresAudio: Bool
    ) async throws {
        do {
            let asset = localAsset(for: url)
            async let videoTracks = asset.loadTracks(withMediaType: .video)
            async let audioTracks = asset.loadTracks(withMediaType: .audio)
            async let isPlayable = asset.load(.isPlayable)
            let (video, audio, playable) = try await (videoTracks, audioTracks, isPlayable)
            guard playable else {
                throw HLSError.remuxFailed("変換後のMP4をこの端末で再生できません")
            }
            guard !video.isEmpty || !audio.isEmpty else {
                throw HLSError.noPlayableTracks
            }
            guard !requiresVideo || !video.isEmpty else {
                throw HLSError.remuxFailed("変換後のMP4に映像トラックがありません")
            }
            guard !requiresAudio || !audio.isEmpty else {
                throw HLSError.remuxFailed("変換後のMP4に音声トラックがありません")
            }
            let duration = try await asset.load(.duration)
            guard isPositiveNumeric(duration) else {
                throw HLSError.remuxFailed("変換後のMP4の長さを取得できません")
            }
        } catch is CancellationError {
            throw HLSError.cancelled
        } catch let error as HLSError {
            throw error
        } catch {
            throw HLSError.remuxFailed(diagnosticDescription(error))
        }
    }

    private func installRemuxedOutput(_ sourceURL: URL, at outputURL: URL) throws {
        do {
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(at: sourceURL, to: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw HLSError.exportFailed(error.localizedDescription)
        }
    }

    private func composeIndividually(
        main: [DownloadedSegment],
        externalAudio: [DownloadedSegment]?,
        outputURL: URL
    ) async throws {
        guard !main.contains(where: { $0.source.hasDiscontinuity }),
              !(externalAudio?.contains(where: { $0.source.hasDiscontinuity }) ?? false) else {
            throw HLSError.invalidPlaylist("EXT-X-DISCONTINUITYを含むHLSは現在MP4化できません")
        }
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
        let audioOrigin: CMTime?
        if let externalAudio {
            audioOrigin = try await firstTrackStart(in: externalAudio, preferredMediaTypes: [.audio])
        } else {
            audioOrigin = nil
        }
        let commonOrigin = earliestTime(mainOrigin, audioOrigin)
        let mainOffset = nonnegativeDifference(mainOrigin, commonOrigin)

        let mainResult = try await append(
            main,
            videoDestination: videoTrack,
            audioDestination: audioTrack,
            includeVideo: true,
            includeAudio: externalAudio == nil,
            requiresVideo: externalAudio != nil,
            requiresAudio: false,
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
                requiresVideo: false,
                requiresAudio: true,
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
        try await export(
            composition,
            inputURLs: main.map(\.fileURL) + (externalAudio?.map(\.fileURL) ?? []),
            to: outputURL
        )
    }

    private struct ConsolidatedInput {
        let segment: DownloadedSegment
        let temporaryURL: URL
    }

    private func shouldRetryWithConsolidatedMedia(_ error: Error) -> Bool {
        guard let hlsError = error as? HLSError else { return true }
        switch hlsError {
        case .mediaOpenFailed, .exportFailed, .noPlayableTracks:
            return true
        default:
            return false
        }
    }

    private func consolidate(_ segments: [DownloadedSegment], label: String) throws -> ConsolidatedInput? {
        let ordered = segments.sorted(by: { $0.source.ordinal < $1.source.ordinal })
        guard ordered.count > 1, let first = ordered.first,
              ordered.allSatisfy({ $0.container == first.container }) else {
            return nil
        }

        if first.container == .isoBaseMedia {
            guard first.source.initializationMap != nil,
                  first.initializationDataLength > 0,
                  ordered.allSatisfy({
                      $0.source.initializationMap == first.source.initializationMap
                          && $0.initializationDataLength == first.initializationDataLength
                  }) else {
                return nil
            }
        }

        let directory = first.fileURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            "\(label)-joined-\(UUID().uuidString).\(first.container.fileExtension)",
            isDirectory: false
        )
        let maximumOutputBytes = try LocalFFmpegOutputLimit.maximumBytes(for: temporaryURL)
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        ) else {
            throw HLSError.network("連結用ファイルを作成できません")
        }

        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            defer { try? handle.close() }

            var totalBytes: Int64 = 0
            for (index, segment) in ordered.enumerated() {
                try Task.checkCancellation()
                let data = try Data(contentsOf: segment.fileURL, options: .mappedIfSafe)
                let skipCount: Int
                if first.container == .isoBaseMedia, index > 0 {
                    skipCount = segment.initializationDataLength
                } else if index > 0,
                          [.aac, .mp3, .ac3, .eac3].contains(first.container) {
                    skipCount = MediaPayloadInspector.leadingID3Length(
                        [UInt8](data.prefix(262_144))
                    ) ?? 0
                } else {
                    skipCount = 0
                }
                guard skipCount <= data.count else {
                    throw HLSError.invalidPlaylist("断片の初期化データ長が不正です")
                }
                let chunk = skipCount == 0 ? data : Data(data.dropFirst(skipCount))
                let chunkBytes = Int64(chunk.count)
                guard totalBytes < maximumOutputBytes,
                      chunkBytes < maximumOutputBytes - totalBytes else {
                    throw HLSError.exportFailed("consolidated input exceeded storage limit")
                }
                try handle.write(contentsOf: chunk)
                totalBytes += chunkBytes
            }
            try handle.synchronize()
            try LocalFFmpegOutputLimit.validateCompletedOutput(
                at: temporaryURL,
                maximumBytes: maximumOutputBytes
            )

            let duration = ordered.reduce(0.0) { $0 + $1.source.duration }
            let source = MediaSegment(
                ordinal: 0,
                mediaSequence: first.source.mediaSequence,
                duration: duration,
                url: first.source.url,
                byteRange: nil,
                encryption: nil,
                initializationMap: nil,
                hasDiscontinuity: false
            )
            return ConsolidatedInput(
                segment: DownloadedSegment(
                    source: source,
                    fileURL: temporaryURL,
                    container: first.container,
                    byteCount: Int(clamping: totalBytes),
                    initializationDataLength: 0
                ),
                temporaryURL: temporaryURL
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func append(
        _ segments: [DownloadedSegment],
        videoDestination: AVMutableCompositionTrack,
        audioDestination: AVMutableCompositionTrack,
        includeVideo: Bool,
        includeAudio: Bool,
        requiresVideo: Bool,
        requiresAudio: Bool,
        initialTimeline: CMTime
    ) async throws -> (hasVideo: Bool, hasAudio: Bool, endTime: CMTime) {
        var timeline = initialTimeline
        var hasVideo = false
        var hasAudio = false
        var appliedVideoTransform = false
        var expectedVideoPresence: Bool?
        var expectedAudioPresence: Bool?

        for segment in segments.sorted(by: { $0.source.ordinal < $1.source.ordinal }) {
            try Task.checkCancellation()
            do {
                let asset = localAsset(for: segment.fileURL)
                let declaredDuration = CMTime(
                    seconds: segment.source.duration,
                    preferredTimescale: 1_000_000
                )
                let advance: CMTime
                if isPositiveNumeric(declaredDuration) {
                    advance = declaredDuration
                } else {
                    advance = try await asset.load(.duration)
                }
                guard isPositiveNumeric(advance) else {
                    throw HLSError.invalidPlaylist("断片\(segment.source.ordinal + 1)の長さを取得できません")
                }

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
                if requiresVideo && sourceVideo == nil {
                    throw mediaProblem(for: segment, detail: "映像トラックがありません")
                }
                if requiresAudio && sourceAudio == nil {
                    throw mediaProblem(for: segment, detail: "音声トラックがありません")
                }
                if includeVideo {
                    let isPresent = sourceVideo != nil
                    if let expectedVideoPresence, expectedVideoPresence != isPresent {
                        throw mediaProblem(for: segment, detail: "途中で映像トラック構成が変わっています")
                    }
                    expectedVideoPresence = isPresent
                }
                if includeAudio {
                    let isPresent = sourceAudio != nil
                    if let expectedAudioPresence, expectedAudioPresence != isPresent {
                        throw mediaProblem(for: segment, detail: "途中で音声トラック構成が変わっています")
                    }
                    expectedAudioPresence = isPresent
                }
                let commonStart = earliestStart(videoRange, audioRange)

                if let sourceVideo, let videoRange {
                    let offset = nonnegativeDifference(videoRange.start, commonStart)
                    let availableDuration = CMTimeSubtract(advance, offset)
                    guard isPositiveNumeric(availableDuration), isPositiveNumeric(videoRange.duration) else {
                        throw mediaProblem(for: segment, detail: "映像トラックの時間情報が不正です")
                    }
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
                    guard isPositiveNumeric(availableDuration), isPositiveNumeric(audioRange.duration) else {
                        throw mediaProblem(for: segment, detail: "音声トラックの時間情報が不正です")
                    }
                    let range = clipped(audioRange, maximumDuration: availableDuration)
                    try audioDestination.insertTimeRange(range, of: sourceAudio, at: CMTimeAdd(timeline, offset))
                    hasAudio = true
                }

                timeline = CMTimeAdd(timeline, advance)
            } catch is CancellationError {
                throw HLSError.cancelled
            } catch let error as HLSError {
                throw error
            } catch {
                throw mediaOpenError(for: segment, error: error)
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
                do {
                    let asset = localAsset(for: segment.fileURL)
                    if let track = try await asset.loadTracks(withMediaType: mediaType).first {
                        let range = try await track.load(.timeRange)
                        return range.start
                    }
                } catch is CancellationError {
                    throw HLSError.cancelled
                } catch let error as HLSError {
                    throw error
                } catch {
                    throw mediaOpenError(for: segment, error: error)
                }
            }
        }
        return nil
    }

    private func localAsset(for url: URL) -> AVURLAsset {
        AVURLAsset(url: url)
    }

    private func mediaOpenError(for segment: DownloadedSegment, error: Error) -> HLSError {
        mediaProblem(for: segment, detail: diagnosticDescription(error))
    }

    private func mediaProblem(for segment: DownloadedSegment, detail: String) -> HLSError {
        HLSError.mediaOpenFailed(
            stream: segment.fileURL.lastPathComponent.hasPrefix("audio-") ? "音声" : "映像",
            number: segment.source.ordinal + 1,
            container: segment.container.rawValue,
            byteCount: segment.byteCount,
            detail: detail
        )
    }

    private func diagnosticDescription(_ error: Error) -> String {
        let nsError = error as NSError
        var parts = ["\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"]
        if let reason = nsError.localizedFailureReason, reason != nsError.localizedDescription {
            parts.append(reason)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying \(underlying.domain) \(underlying.code)")
        }
        return parts.joined(separator: " / ")
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

    private func export(
        _ composition: AVMutableComposition,
        inputURLs: [URL],
        to outputURL: URL
    ) async throws {
        let presets = [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
        var lastError: Error?

        for preset in presets {
            try Task.checkCancellation()
            let maximumOutputBytes = try LocalFFmpegOutputLimit.maximumBytes(for: outputURL)
            try LocalFFmpegOutputLimit.validateInputFiles(
                inputURLs,
                maximumBytes: maximumOutputBytes
            )
            try? FileManager.default.removeItem(at: outputURL)
            guard let exporter = AVAssetExportSession(asset: composition, presetName: preset),
                  exporter.supportedFileTypes.contains(.mp4) else { continue }

            exporter.outputURL = outputURL
            exporter.outputFileType = .mp4
            exporter.shouldOptimizeForNetworkUse = true
            let estimatedBytes = exporter.estimatedOutputFileLength

            do {
                guard estimatedBytes <= 0 || estimatedBytes < maximumOutputBytes else {
                    throw HLSError.exportFailed("estimated MP4 output exceeds storage limit")
                }
                try await run(
                    exporter,
                    outputURL: outputURL,
                    maximumOutputBytes: maximumOutputBytes
                )
                let values = try outputURL.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? 0) > 0 else {
                    throw HLSError.exportFailed("出力が空です")
                }
                try LocalFFmpegOutputLimit.validateCompletedOutput(
                    at: outputURL,
                    maximumBytes: maximumOutputBytes
                )
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

    private func run(
        _ exporter: AVAssetExportSession,
        outputURL: URL,
        maximumOutputBytes: Int64
    ) async throws {
        let box = ExportSessionBox(exporter)
        let monitor = Task.detached(priority: .utility) { () -> Void in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
                guard let size = try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      Int64(size) >= maximumOutputBytes else {
                    continue
                }
                box.markOutputLimitExceeded()
                box.session.cancelExport()
                return
            }
        }
        defer { monitor.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.session.exportAsynchronously {
                    if box.didExceedOutputLimit() {
                        continuation.resume(
                            throwing: HLSError.exportFailed("MP4 output exceeded storage limit")
                        )
                        return
                    }
                    switch box.session.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: HLSError.cancelled)
                    case .failed:
                        continuation.resume(
                            throwing: HLSError.exportFailed(box.session.error?.localizedDescription ?? "AVFoundationエラー")
                        )
                    default:
                        continuation.resume(throwing: HLSError.exportFailed("予期しない終了状態です"))
                    }
                }
            }
        } onCancel: {
            box.session.cancelExport()
        }
    }
}
