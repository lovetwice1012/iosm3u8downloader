import Combine
import Foundation
import ImageIO
import UIKit

@MainActor
final class DownloadViewModel: ObservableObject {
    @Published var inputURL = "" {
        didSet {
            let normalized = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized != discoveredInput {
                diagnosticSessionID = nil
                cancelActiveOperation()
                candidates = []
                thumbnails = [:]
                attemptedThumbnailIDs = []
                thumbnailIDsInFlight = []
            }
        }
    }
    @Published private(set) var progress = DownloadProgress(phase: .idle, completedItems: 0, totalItems: 0)
    @Published private(set) var outputURL: URL?
    @Published private(set) var downloadedSegmentCount = 0
    @Published private(set) var candidates: [HLSCandidate] = []
    @Published private(set) var thumbnails: [UUID: UIImage] = [:]
    @Published private(set) var diagnosticLog = ""
    @Published private(set) var isCancelling = false
    @Published private(set) var isOperationActive = false
    @Published private(set) var playbackCaptureSession: PlaybackCaptureSession?
    @Published private(set) var isPlaybackCapturePresented = false
    @Published private(set) var isPreparingPlaybackCapture = false
    @Published private(set) var isFinalizingPlaybackCapture = false
    @Published var errorMessage: String?

    private let service: any HLSDownloadServicing
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var diagnosticSessionID: UUID?
    private var cancellingOperationIDs = Set<UUID>()
    private var discoveredInput: String?
    private var playbackCaptureInput: String?
    private var attemptedThumbnailIDs = Set<UUID>()
    private var thumbnailIDsInFlight = Set<UUID>()

    init(service: (any HLSDownloadServicing)? = nil) {
        self.service = service ?? HLSDownloadService()
    }

    var isRunning: Bool {
        [.resolving, .downloading, .composing].contains(progress.phase)
    }

    var isBusy: Bool {
        isOperationActive
            || isCancelling
            || playbackCaptureSession != nil
            || isPreparingPlaybackCapture
            || isFinalizingPlaybackCapture
    }

    var canStart: Bool {
        !isBusy && !inputURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func paste() {
        guard let value = UIPasteboard.general.string else { return }
        inputURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start() {
        guard canStart else { return }
        task?.cancel()
        outputURL = nil
        downloadedSegmentCount = 0
        errorMessage = nil
        candidates = []
        thumbnails = [:]
        attemptedThumbnailIDs = []
        thumbnailIDsInFlight = []
        discoveredInput = nil
        service.resetDiagnosticLog()
        diagnosticLog = service.diagnosticLogText()
        let input = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        progress = DownloadProgress(phase: .resolving, completedItems: 0, totalItems: 0)
        let operationID = UUID()
        let diagnosticSessionID = UUID()
        self.operationID = operationID
        self.diagnosticSessionID = diagnosticSessionID
        isOperationActive = true

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let discovery = try await service.discover(input: input)
                try Task.checkCancellation()
                guard isCurrentOperation(operationID, input: input) else { return }

                if discovery.isDirectPlaylist, let candidate = discovery.candidates.first {
                    let result = try await service.download(candidate: candidate) { [weak self] update in
                        await self?.apply(update, operationID: operationID)
                    }
                    try Task.checkCancellation()
                    guard isCurrentOperation(operationID, input: input) else { return }
                    apply(result)
                } else {
                    discoveredInput = input
                    candidates = discovery.candidates
                    progress = DownloadProgress(phase: .idle, completedItems: 0, totalItems: 0)
                }
            } catch {
                if self.operationID == operationID { handle(error) }
            }
            if self.diagnosticSessionID == diagnosticSessionID { refreshDiagnosticLog() }
            finishOperation(operationID)
        }
    }

    func startPlaybackCapture() {
        guard canStart else { return }
        task?.cancel()
        outputURL = nil
        downloadedSegmentCount = 0
        errorMessage = nil
        service.resetDiagnosticLog()
        diagnosticLog = service.diagnosticLogText()

        let input = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let operationID = UUID()
        let diagnosticSessionID = UUID()
        self.operationID = operationID
        self.diagnosticSessionID = diagnosticSessionID
        isOperationActive = true
        isPreparingPlaybackCapture = true
        progress = DownloadProgress(phase: .resolving, completedItems: 0, totalItems: 0)

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await service.preparePlaybackCapture(input: input)
                if !Task.isCancelled, isCurrentOperation(operationID, input: input) {
                    playbackCaptureSession = session
                    playbackCaptureInput = input
                    discoveredInput = input
                    isPlaybackCapturePresented = true
                    progress = DownloadProgress(phase: .idle, completedItems: 0, totalItems: 0)
                } else {
                    _ = await service.finishPlaybackCapture(session)
                }
            } catch {
                if self.operationID == operationID { handle(error) }
            }

            isPreparingPlaybackCapture = false
            if self.diagnosticSessionID == diagnosticSessionID { refreshDiagnosticLog() }
            finishOperation(operationID)
        }
    }

    func finishPlaybackCapture() {
        finishPlaybackCapture(mergingResults: true)
    }

    func playbackCaptureDidEnterBackground() {
        if playbackCaptureSession != nil {
            finishPlaybackCapture()
        } else if isPreparingPlaybackCapture {
            cancelActiveOperation()
        }
    }

    func download(_ candidate: HLSCandidate) {
        guard !isBusy, candidates.contains(where: { $0.id == candidate.id }) else { return }
        task?.cancel()
        outputURL = nil
        downloadedSegmentCount = 0
        errorMessage = nil
        progress = DownloadProgress(phase: .resolving, completedItems: 0, totalItems: 0)
        let input = discoveredInput ?? inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let operationID = UUID()
        let diagnosticSessionID = self.diagnosticSessionID ?? UUID()
        self.operationID = operationID
        self.diagnosticSessionID = diagnosticSessionID
        isOperationActive = true

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.download(candidate: candidate) { [weak self] update in
                    await self?.apply(update, operationID: operationID)
                }
                try Task.checkCancellation()
                guard isCurrentOperation(operationID, input: input) else { return }
                apply(result)
            } catch {
                if self.operationID == operationID { handle(error) }
            }
            if self.diagnosticSessionID == diagnosticSessionID { refreshDiagnosticLog() }
            finishOperation(operationID)
        }
    }

    func loadThumbnail(for candidate: HLSCandidate) async {
        guard candidate.thumbnailURL != nil,
              thumbnails[candidate.id] == nil,
              !attemptedThumbnailIDs.contains(candidate.id),
              thumbnailIDsInFlight.insert(candidate.id).inserted else {
            return
        }
        defer { thumbnailIDsInFlight.remove(candidate.id) }
        guard !Task.isCancelled else { return }
        let data = await service.thumbnailData(for: candidate)
        guard !Task.isCancelled,
              candidates.contains(where: { $0.id == candidate.id }) else {
            return
        }
        attemptedThumbnailIDs.insert(candidate.id)
        guard let data, let image = downsampledImage(from: data) else { return }
        thumbnails[candidate.id] = image
    }

    func cancel() {
        guard !isFinalizingPlaybackCapture else { return }
        cancelActiveOperation()
        refreshDiagnosticLog()
    }

    func refreshDiagnosticLog() {
        diagnosticLog = service.diagnosticLogText()
    }

    func copyDiagnosticLog() {
        refreshDiagnosticLog()
        guard !diagnosticLog.isEmpty else { return }
        UIPasteboard.general.string = diagnosticLog
    }

    private func apply(_ result: DownloadResult) {
        outputURL = result.outputURL
        downloadedSegmentCount = result.segmentCount
    }

    private func apply(_ update: DownloadProgress, operationID: UUID) {
        guard self.operationID == operationID else { return }
        progress = update
    }

    private func isCurrentOperation(_ operationID: UUID, input: String) -> Bool {
        self.operationID == operationID
            && inputURL.trimmingCharacters(in: .whitespacesAndNewlines) == input
    }

    private func finishOperation(_ operationID: UUID) {
        if self.operationID == operationID {
            task = nil
            self.operationID = nil
        }
        if cancellingOperationIDs.remove(operationID) != nil {
            isCancelling = !cancellingOperationIDs.isEmpty
        }
        isOperationActive = false
    }

    private func finishPlaybackCapture(mergingResults: Bool) {
        guard !isFinalizingPlaybackCapture,
              let session = playbackCaptureSession else {
            return
        }

        isFinalizingPlaybackCapture = true
        errorMessage = nil
        let captureInput = playbackCaptureInput
        let operationID = UUID()
        let diagnosticSessionID = self.diagnosticSessionID ?? UUID()
        self.operationID = operationID
        self.diagnosticSessionID = diagnosticSessionID
        isOperationActive = true

        task = Task { [weak self] in
            guard let self else { return }
            let capturedCandidates = await service.finishPlaybackCapture(session)
            let inputStillMatches = captureInput == inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if mergingResults, inputStillMatches {
                mergeCandidates(capturedCandidates)
                if capturedCandidates.isEmpty, candidates.isEmpty {
                    errorMessage = "再生通信からHLS候補を検出できませんでした。動画を再生してから、もう一度お試しください。"
                }
            }

            if playbackCaptureSession === session {
                playbackCaptureSession = nil
                playbackCaptureInput = nil
                isPlaybackCapturePresented = false
            }
            isFinalizingPlaybackCapture = false
            progress = DownloadProgress(phase: .idle, completedItems: 0, totalItems: 0)
            if self.diagnosticSessionID == diagnosticSessionID { refreshDiagnosticLog() }
            finishOperation(operationID)
        }
    }

    private func mergeCandidates(_ newCandidates: [HLSCandidate]) {
        for candidate in newCandidates {
            let identity = candidateIdentity(candidate)
            if let index = candidates.firstIndex(where: { candidateIdentity($0) == identity }) {
                let existing = candidates[index]
                candidates[index] = HLSCandidate(
                    id: existing.id,
                    request: existing.request.sameOriginQueryFallback != nil
                        ? existing.request : candidate.request,
                    requestReferer: existing.requestReferer ?? candidate.requestReferer,
                    document: existing.document ?? candidate.document,
                    pageURL: existing.pageURL,
                    title: existing.title ?? candidate.title,
                    thumbnailURL: existing.thumbnailURL ?? candidate.thumbnailURL,
                    iframeDepth: min(existing.iframeDepth, candidate.iframeDepth),
                    origin: existing.origin
                )
            } else {
                candidates.append(candidate)
            }
        }
    }

    private func candidateIdentity(_ candidate: HLSCandidate) -> String {
        canonicalURL(candidate.playlistURL)
            + "\n"
            + canonicalURL(candidate.requestReferer ?? candidate.pageURL)
    }

    private func canonicalURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    private func cancelActiveOperation() {
        let activeTask = task
        if activeTask != nil, let operationID {
            cancellingOperationIDs.insert(operationID)
            isCancelling = true
        }
        task = nil
        operationID = nil
        activeTask?.cancel()
        if isRunning {
            progress = DownloadProgress(phase: .idle, completedItems: 0, totalItems: 0)
        }
    }

    private func handle(_ error: Error) {
        if let hlsError = error as? HLSError, case .cancelled = hlsError {
            progress = DownloadProgress(phase: .idle, completedItems: 0, totalItems: 0)
        } else if error is CancellationError {
            progress = DownloadProgress(phase: .idle, completedItems: 0, totalItems: 0)
        } else {
            errorMessage = error.localizedDescription
            progress = DownloadProgress(phase: .idle, completedItems: 0, totalItems: 0)
        }
    }

    private func downsampledImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 480
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}
