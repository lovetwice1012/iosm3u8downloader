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
                discardCapturedFiles(in: candidates)
                candidates = []
                candidatePresentations = []
                selectedResolutionChoiceIDs = [:]
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
    @Published private(set) var candidatePresentations: [CandidatePresentation] = []
    @Published private(set) var selectedResolutionChoiceIDs: [UUID: String] = [:]
    @Published private(set) var thumbnails: [UUID: UIImage] = [:]
    @Published private(set) var diagnosticLog = ""
    @Published private(set) var isCancelling = false
    @Published private(set) var isOperationActive = false
    @Published private(set) var playbackCaptureSession: PlaybackCaptureSession?
    @Published private(set) var isPlaybackCapturePresented = false
    @Published private(set) var isPreparingPlaybackCapture = false
    @Published private(set) var isFinalizingPlaybackCapture = false
    @Published private(set) var hasWidevineCredential = false
    @Published private(set) var isWidevineProcessingConfigured = false
    @Published private(set) var widevineCredentialMessage: String?
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
        hasWidevineCredential = self.service.hasWidevineCredential()
        isWidevineProcessingConfigured = self.service.isWidevineProcessingConfigured()
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

    var hasWidevineCandidates: Bool {
        candidates.contains(where: { $0.kind == .widevineDASH })
    }

    func canDownload(_ candidate: HLSCandidate) -> Bool {
        guard !isBusy else { return false }
        switch candidate.kind {
        case .hls, .progressive:
            return true
        case .widevineDASH:
            return isDownloadableWidevineDomain(candidate.playlistURL)
                && hasWidevineCredential
                && isWidevineProcessingConfigured
        }
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
        discardCapturedFiles(in: candidates)
        candidates = []
        candidatePresentations = []
        selectedResolutionChoiceIDs = [:]
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
                if Task.isCancelled {
                    discardCapturedFiles(in: discovery.candidates)
                    throw HLSError.cancelled
                }
                guard isCurrentOperation(operationID, input: input) else {
                    discardCapturedFiles(in: discovery.candidates)
                    return
                }

                if discovery.isDirectPlaylist,
                   let candidate = discovery.candidates.first,
                   candidate.kind == .hls,
                   HLSResolutionCatalog.options(from: candidate.document).count <= 1 {
                    let result = try await service.download(
                        candidate: candidate,
                        preferredResolution: nil
                    ) { [weak self] update in
                        await self?.apply(update, operationID: operationID)
                    }
                    try Task.checkCancellation()
                    guard isCurrentOperation(operationID, input: input) else { return }
                    apply(result)
                } else {
                    discoveredInput = input
                    discardCapturedFiles(in: candidates)
                    candidates = discovery.candidates
                    reconcileResolutionSelections()
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
        discardCapturedFiles(in: candidates)
        candidates.removeAll(where: { $0.capturedContentID != nil })
        reconcileResolutionSelections()
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
                    let abandoned = await service.finishPlaybackCapture(session)
                    discardCapturedFiles(in: abandoned)
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

    func selectedResolutionChoice(
        for presentation: CandidatePresentation
    ) -> CandidateResolutionChoice? {
        guard !presentation.resolutionChoices.isEmpty else { return nil }
        if let selectedID = selectedResolutionChoiceIDs[presentation.id],
           let selected = presentation.resolutionChoices.first(where: { $0.id == selectedID }) {
            return selected
        }
        return presentation.resolutionChoices.first
    }

    func selectResolutionChoice(
        _ choice: CandidateResolutionChoice,
        for presentation: CandidatePresentation
    ) {
        guard presentation.resolutionChoices.contains(where: { $0.id == choice.id }) else { return }
        selectedResolutionChoiceIDs[presentation.id] = choice.id
    }

    func canDownload(_ presentation: CandidatePresentation) -> Bool {
        guard let candidate = selectedCandidate(for: presentation) else { return false }
        return canDownload(candidate)
    }

    func download(_ presentation: CandidatePresentation) {
        guard let candidate = selectedCandidate(for: presentation) else { return }
        download(
            candidate,
            preferredResolution: selectedResolutionChoice(for: presentation)?.hlsPreferredResolution
        )
    }

    func download(_ candidate: HLSCandidate) {
        download(candidate, preferredResolution: nil)
    }

    private func download(
        _ candidate: HLSCandidate,
        preferredResolution: MediaResolution?
    ) {
        guard canDownload(candidate),
              candidates.contains(where: { $0.id == candidate.id }) else { return }
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
                let result = try await service.download(
                    candidate: candidate,
                    preferredResolution: preferredResolution
                ) { [weak self] update in
                    await self?.apply(update, operationID: operationID)
                }
                try Task.checkCancellation()
                guard isCurrentOperation(operationID, input: input) else { return }
                apply(result)
                if candidate.capturedContentID != nil {
                    candidates.removeAll(where: { $0.id == candidate.id })
                    reconcileResolutionSelections()
                }
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

    func importWidevineCredential(from url: URL) {
        guard !isBusy else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile != false,
                  (values.fileSize ?? 0) <= 256 * 1_024 else {
                throw WidevineCredentialImportError.fileTooLarge
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 256 * 1_024 else {
                throw WidevineCredentialImportError.fileTooLarge
            }
            let metadata = try service.importWidevineCredential(data)
            hasWidevineCredential = true
            widevineCredentialMessage = "Widevine L\(metadata.securityLevel.rawValue) WVD v\(metadata.version) をKeychainに保存しました。"
            errorMessage = nil
        } catch {
            hasWidevineCredential = service.hasWidevineCredential()
            widevineCredentialMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    func deleteWidevineCredential() {
        guard !isBusy else { return }
        do {
            try service.deleteWidevineCredential()
            hasWidevineCredential = false
            widevineCredentialMessage = "WVDをKeychainから削除しました。"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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
                    if session.detectedMediaSource {
                        errorMessage = "MSEの利用を検出しましたが、元のHLS / DASH manifestまたは完了Blobを取得できませんでした。MSE SourceBuffer単体の保存には対応していません。"
                    } else {
                        errorMessage = "再生通信からHLS / Widevine候補を検出できませんでした。動画を再生してから、もう一度お試しください。"
                    }
                }
            } else {
                discardCapturedFiles(in: capturedCandidates)
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
                candidates[index] = CandidateMergePolicy.merge(existing, candidate)
            } else {
                candidates.append(candidate)
            }
        }
        reconcileResolutionSelections()
    }

    private func selectedCandidate(for presentation: CandidatePresentation) -> HLSCandidate? {
        let selectedID = selectedResolutionChoice(for: presentation)?.candidateID
            ?? presentation.candidate.id
        return candidates.first(where: { $0.id == selectedID })
    }

    private func reconcileResolutionSelections() {
        let presentations = CandidatePresentationPolicy.presentations(from: candidates)
        candidatePresentations = presentations
        selectedResolutionChoiceIDs = selectedResolutionChoiceIDs.filter {
            presentationID, choiceID in
            guard let presentation = presentations.first(where: { $0.id == presentationID }) else {
                return false
            }
            return presentation.resolutionChoices.contains(where: { $0.id == choiceID })
        }
    }

    private func candidateIdentity(_ candidate: HLSCandidate) -> String {
        if let capturedContentID = candidate.capturedContentID {
            return candidate.kind.rawValue
                + "\ncapture:"
                + capturedContentID.uuidString.lowercased()
        }
        return candidate.kind.rawValue
            + "\n"
            + canonicalURL(candidate.request.primary)
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

    private func discardCapturedFiles(in candidates: [HLSCandidate]) {
        for candidate in candidates {
            guard let progressiveMedia = candidate.progressiveMedia,
                  case .capturedBlob(let fileURL, _) = progressiveMedia.storage else {
                continue
            }
            WebBlobCaptureStore.discardCaptureFile(at: fileURL)
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

enum CandidateMergePolicy {
    static func merge(_ existing: HLSCandidate, _ candidate: HLSCandidate) -> HLSCandidate {
        HLSCandidate(
            id: existing.id,
            kind: existing.kind,
            request: existing.request.sameOriginQueryFallback != nil
                ? existing.request : candidate.request,
            requestReferer: existing.requestReferer ?? candidate.requestReferer,
            document: existing.document ?? candidate.document,
            progressiveMedia: existing.progressiveMedia ?? candidate.progressiveMedia,
            mediaGroupID: existing.mediaGroupID ?? candidate.mediaGroupID,
            usesCapturedDocument: existing.usesCapturedDocument || candidate.usesCapturedDocument,
            capturedContentID: existing.capturedContentID ?? candidate.capturedContentID,
            widevinePlaybackContext: existing.widevinePlaybackContext
                ?? candidate.widevinePlaybackContext,
            pageURL: existing.pageURL,
            title: existing.title ?? candidate.title,
            thumbnailURL: existing.thumbnailURL ?? candidate.thumbnailURL,
            iframeDepth: min(existing.iframeDepth, candidate.iframeDepth),
            origin: existing.origin
        )
    }
}

struct CandidateResolutionChoice: Identifiable, Equatable {
    let id: String
    let resolution: MediaResolution
    let bandwidth: Int?
    let candidateID: UUID
    let hlsPreferredResolution: MediaResolution?

    var displayTitle: String {
        guard let bandwidth, bandwidth > 0 else { return resolution.displayTitle }
        return HLSResolutionOption(
            resolution: resolution,
            bandwidth: bandwidth
        ).displayTitle
    }
}

struct CandidatePresentation: Identifiable {
    let id: UUID
    let candidate: HLSCandidate
    let resolutionChoices: [CandidateResolutionChoice]
}

enum CandidatePresentationPolicy {
    static func presentations(from candidates: [HLSCandidate]) -> [CandidatePresentation] {
        let progressiveGroups = progressiveResolutionGroups(in: candidates)
        let suppressedHLSCandidateIDs = hlsVariantCandidateIDsToSuppress(in: candidates)
        var emittedGroups = Set<String>()
        var result: [CandidatePresentation] = []

        for candidate in candidates {
            if suppressedHLSCandidateIDs.contains(candidate.id) { continue }
            if let key = progressiveGroupKey(candidate),
               let members = progressiveGroups[key],
               emittedGroups.insert(key).inserted {
                let choices = progressiveChoices(from: members)
                guard choices.count > 1,
                      let representativeID = choices.first?.candidateID,
                      let representative = members.first(where: { $0.id == representativeID }) else {
                    result.append(singlePresentation(candidate))
                    continue
                }
                result.append(
                    CandidatePresentation(
                        id: representative.id,
                        candidate: representative,
                        resolutionChoices: choices
                    )
                )
                continue
            }
            if let key = progressiveGroupKey(candidate), progressiveGroups[key] != nil {
                continue
            }

            let hlsOptions = candidate.kind == .hls
                ? HLSResolutionCatalog.options(from: candidate.document)
                : []
            let hlsChoices = hlsOptions.count > 1 ? hlsOptions.map { option in
                CandidateResolutionChoice(
                    id: "hls:\(option.id)",
                    resolution: option.resolution,
                    bandwidth: option.bandwidth,
                    candidateID: candidate.id,
                    hlsPreferredResolution: option.resolution
                )
            } : []
            result.append(
                CandidatePresentation(
                    id: candidate.id,
                    candidate: candidate,
                    resolutionChoices: hlsChoices
                )
            )
        }
        return result
    }

    private static func singlePresentation(_ candidate: HLSCandidate) -> CandidatePresentation {
        CandidatePresentation(id: candidate.id, candidate: candidate, resolutionChoices: [])
    }

    private static func progressiveResolutionGroups(
        in candidates: [HLSCandidate]
    ) -> [String: [HLSCandidate]] {
        var grouped: [String: [HLSCandidate]] = [:]
        for candidate in candidates {
            guard let key = progressiveGroupKey(candidate) else { continue }
            grouped[key, default: []].append(candidate)
        }
        var result: [String: [HLSCandidate]] = [:]
        for (key, members) in grouped {
            let distinct = Set(members.compactMap { $0.progressiveMedia?.resolution })
            if distinct.count > 1 { result[key] = members }
        }
        return result
    }

    private static func progressiveChoices(
        from candidates: [HLSCandidate]
    ) -> [CandidateResolutionChoice] {
        var bestByResolution: [MediaResolution: HLSCandidate] = [:]
        for candidate in candidates {
            guard let resolution = candidate.progressiveMedia?.resolution else { continue }
            if bestByResolution[resolution] == nil { bestByResolution[resolution] = candidate }
        }
        return bestByResolution.map { resolution, candidate in
            CandidateResolutionChoice(
                id: "progressive:\(candidate.id.uuidString.lowercased())",
                resolution: resolution,
                bandwidth: nil,
                candidateID: candidate.id,
                hlsPreferredResolution: nil
            )
        }.sorted { lhs, rhs in
            if lhs.resolution.pixelCount != rhs.resolution.pixelCount {
                return lhs.resolution.pixelCount > rhs.resolution.pixelCount
            }
            return lhs.resolution.id > rhs.resolution.id
        }
    }

    private static func progressiveGroupKey(_ candidate: HLSCandidate) -> String? {
        guard candidate.kind == .progressive,
              candidate.capturedContentID == nil,
              let reference = candidate.progressiveMedia,
              case .remote = reference.storage,
              reference.resolution != nil,
              let container = reference.container,
              let groupID = candidate.mediaGroupID,
              !groupID.isEmpty else {
            return nil
        }
        return canonicalURL(candidate.pageURL)
            + "\n\(candidate.iframeDepth)\n"
            + container.rawValue
            + "\n" + groupID
    }

    private static func hlsVariantCandidateIDsToSuppress(
        in candidates: [HLSCandidate]
    ) -> Set<UUID> {
        var suppressed = Set<UUID>()
        for masterCandidate in candidates where masterCandidate.kind == .hls {
            guard HLSResolutionCatalog.options(from: masterCandidate.document).count > 1,
                  let document = masterCandidate.document,
                  let parsed = try? PlaylistParser.parse(
                    text: document.text,
                    effectiveURL: document.effectiveURL,
                    requestReferer: document.referer
                  ),
                  case .master(let master) = parsed else {
                continue
            }
            let variantURLs = Set(master.variants.flatMap { $0.url.all }.map(canonicalURL))
            let masterPage = canonicalURL(masterCandidate.pageURL)
            let masterReferer = canonicalURL(
                masterCandidate.requestReferer ?? masterCandidate.pageURL
            )
            for candidate in candidates where candidate.id != masterCandidate.id
                && candidate.kind == .hls {
                guard canonicalURL(candidate.pageURL) == masterPage,
                      canonicalURL(candidate.requestReferer ?? candidate.pageURL) == masterReferer,
                      candidate.request.all.contains(where: {
                        variantURLs.contains(canonicalURL($0))
                      }) else {
                    continue
                }
                suppressed.insert(candidate.id)
            }
        }
        return suppressed
    }

    private static func canonicalURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.string ?? url.absoluteString
    }
}

private enum WidevineCredentialImportError: LocalizedError {
    case fileTooLarge

    var errorDescription: String? {
        "WVDファイルが大きすぎます。"
    }
}
