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
    @Published var errorMessage: String?

    private let service: any HLSDownloadServicing
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var discoveredInput: String?
    private var attemptedThumbnailIDs = Set<UUID>()
    private var thumbnailIDsInFlight = Set<UUID>()

    init(service: (any HLSDownloadServicing)? = nil) {
        self.service = service ?? HLSDownloadService()
    }

    var isRunning: Bool {
        [.resolving, .downloading, .composing].contains(progress.phase)
    }

    var canStart: Bool {
        !isRunning && !inputURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        let input = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        progress = DownloadProgress(phase: .resolving, completedItems: 0, totalItems: 0)
        let operationID = UUID()
        self.operationID = operationID

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
            finishOperation(operationID)
        }
    }

    func download(_ candidate: HLSCandidate) {
        guard !isRunning, candidates.contains(where: { $0.id == candidate.id }) else { return }
        task?.cancel()
        outputURL = nil
        downloadedSegmentCount = 0
        errorMessage = nil
        progress = DownloadProgress(phase: .resolving, completedItems: 0, totalItems: 0)
        let input = discoveredInput ?? inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let operationID = UUID()
        self.operationID = operationID

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
        cancelActiveOperation()
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
        guard self.operationID == operationID else { return }
        task = nil
        self.operationID = nil
    }

    private func cancelActiveOperation() {
        let activeTask = task
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
