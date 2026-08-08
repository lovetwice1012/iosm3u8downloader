import Combine
import Foundation
import UIKit

@MainActor
final class DownloadViewModel: ObservableObject {
    @Published var inputURL = ""
    @Published private(set) var progress = DownloadProgress(phase: .idle, completedItems: 0, totalItems: 0)
    @Published private(set) var outputURL: URL?
    @Published private(set) var downloadedSegmentCount = 0
    @Published var errorMessage: String?

    private let service = HLSDownloadService()
    private var task: Task<Void, Never>?

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
        let input = inputURL

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.download(input: input) { [weak self] update in
                    await self?.apply(update)
                }
                outputURL = result.outputURL
                downloadedSegmentCount = result.segmentCount
            } catch {
                if let hlsError = error as? HLSError, case .cancelled = hlsError {
                    progress = DownloadProgress(phase: .idle, completedItems: 0, totalItems: 0)
                } else {
                    errorMessage = error.localizedDescription
                    progress = DownloadProgress(phase: .idle, completedItems: 0, totalItems: 0)
                }
            }
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func apply(_ update: DownloadProgress) {
        progress = update
    }
}
