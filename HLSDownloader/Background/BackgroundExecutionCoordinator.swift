import BackgroundTasks
import Foundation
import UIKit

enum BackgroundExecutionError: LocalizedError, Equatable {
    case alreadyRunning
    case expired

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "別のバックグラウンド処理が実行中です"
        case .expired:
            return "バックグラウンド実行時間が終了したため処理を中断しました"
        }
    }
}

struct BackgroundExecutionProgressUpdate: Equatable, Sendable {
    let completedUnitCount: Int64
    let totalUnitCount: Int64
    let subtitle: String?

    init(completedUnitCount: Int64, totalUnitCount: Int64, subtitle: String? = nil) {
        let safeTotal = max(1, totalUnitCount)
        self.completedUnitCount = min(max(0, completedUnitCount), safeTotal)
        self.totalUnitCount = safeTotal
        self.subtitle = subtitle
    }

    init(downloadProgress: DownloadProgress) {
        let total: Int64 = 1_000
        let completed: Int64
        switch downloadProgress.phase {
        case .idle:
            completed = 0
        case .resolving:
            completed = 25
        case .downloading:
            if let fraction = downloadProgress.fraction {
                completed = 50 + Int64((fraction * 850).rounded(.down))
            } else {
                completed = 50
            }
        case .composing:
            completed = 925
        case .completed:
            completed = total
        }
        self.init(
            completedUnitCount: completed,
            totalUnitCount: total,
            subtitle: downloadProgress.phase.title
        )
    }
}

struct BackgroundExecutionProgressReporter: Sendable {
    private let reportHandler: @Sendable (BackgroundExecutionProgressUpdate) async -> Void

    init(
        reportHandler: @escaping @Sendable (BackgroundExecutionProgressUpdate) async -> Void
    ) {
        self.reportHandler = reportHandler
    }

    func report(
        completedUnitCount: Int64,
        totalUnitCount: Int64,
        subtitle: String? = nil
    ) async {
        await reportHandler(
            BackgroundExecutionProgressUpdate(
                completedUnitCount: completedUnitCount,
                totalUnitCount: totalUnitCount,
                subtitle: subtitle
            )
        )
    }

    func report(_ progress: DownloadProgress) async {
        await reportHandler(BackgroundExecutionProgressUpdate(downloadProgress: progress))
    }
}

struct ShortBackgroundTaskToken: Hashable, Sendable {
    let rawValue: UInt64
}

@MainActor
protocol ShortBackgroundTaskManaging: AnyObject {
    func beginTask(
        name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) -> ShortBackgroundTaskToken
    func endTask(_ token: ShortBackgroundTaskToken)
}

@MainActor
final class UIApplicationShortBackgroundTaskManager: ShortBackgroundTaskManaging {
    private var nextRawValue: UInt64 = 1
    private var systemIdentifiers: [ShortBackgroundTaskToken: UIBackgroundTaskIdentifier] = [:]

    func beginTask(
        name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) -> ShortBackgroundTaskToken {
        let token = ShortBackgroundTaskToken(rawValue: nextRawValue)
        nextRawValue &+= 1
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: name,
            expirationHandler: expirationHandler
        )
        systemIdentifiers[token] = identifier
        return token
    }

    func endTask(_ token: ShortBackgroundTaskToken) {
        guard let identifier = systemIdentifiers.removeValue(forKey: token),
              identifier != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

@MainActor
final class BackgroundExecutionCoordinator {
    static func taskIdentifier(bundleIdentifier: String, jobID: UUID) -> String {
        let suffix = jobID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return "\(bundleIdentifier).continued-download.\(suffix)"
    }
    static let shared = BackgroundExecutionCoordinator()

    enum ContinuedProcessingPolicy: Equatable {
        case automatic
        case disabled
    }

    private enum CompletionDecision {
        case ignore
        case resume(overrideError: Error?)
    }

    private final class Job {
        enum ExecutionMode: String {
            case pending
            case continued
            case shortAllowance
        }

        let id: UUID
        let taskIdentifier: String
        let title: String
        let subtitle: String
        let startWork: @MainActor (BackgroundExecutionProgressReporter) -> Task<Void, Never>
        let failBeforeStart: @MainActor (Error) -> Void
        let diagnosticSink: DiagnosticSink?
        var workTask: Task<Void, Never>?
        var launchTimeoutTask: Task<Void, Never>?
        var shortTaskToken: ShortBackgroundTaskToken?
        var continuedTask: AnyObject?
        var overrideError: Error?
        var started = false
        var completed = false
        var executionMode: ExecutionMode = .pending

        init(
            id: UUID,
            taskIdentifier: String,
            title: String,
            subtitle: String,
            startWork: @escaping @MainActor (BackgroundExecutionProgressReporter) -> Task<Void, Never>,
            failBeforeStart: @escaping @MainActor (Error) -> Void,
            diagnosticSink: DiagnosticSink?
        ) {
            self.id = id
            self.taskIdentifier = taskIdentifier
            self.title = title
            self.subtitle = subtitle
            self.startWork = startWork
            self.failBeforeStart = failBeforeStart
            self.diagnosticSink = diagnosticSink
        }
    }

    private let shortTaskManager: any ShortBackgroundTaskManaging
    private let continuedProcessingPolicy: ContinuedProcessingPolicy
    private var activeJob: Job?

    init(
        shortTaskManager: (any ShortBackgroundTaskManaging)? = nil,
        continuedProcessingPolicy: ContinuedProcessingPolicy = .automatic
    ) {
        self.shortTaskManager = shortTaskManager ?? UIApplicationShortBackgroundTaskManager()
        self.continuedProcessingPolicy = continuedProcessingPolicy
    }

    /// Runs one user-initiated operation with iOS 26 continued-processing support.
    ///
    /// On iOS 17-25, or when registration/submission is unavailable, the operation starts
    /// immediately under UIKit's short background-time allowance. Only one operation may run.
    func run<T: Sendable>(
        title: String,
        subtitle: String,
        diagnosticSink: DiagnosticSink? = nil,
        operation: @escaping @Sendable (BackgroundExecutionProgressReporter) async throws -> T
    ) async throws -> T {
        guard activeJob == nil else { throw BackgroundExecutionError.alreadyRunning }
        try Task.checkCancellation()

        let jobID = UUID()
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.example.HLSDownloader"
        let taskIdentifier = Self.taskIdentifier(
            bundleIdentifier: bundleIdentifier,
            jobID: jobID
        )
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let job = Job(
                    id: jobID,
                    taskIdentifier: taskIdentifier,
                    title: String(title.prefix(80)),
                    subtitle: String(subtitle.prefix(160)),
                    startWork: { [self] reporter in
                        Task {
                            do {
                                let value = try await operation(reporter)
                                switch self.completeJob(id: jobID, succeeded: true) {
                                case .ignore:
                                    return
                                case .resume(let overrideError):
                                    if let overrideError {
                                        continuation.resume(throwing: overrideError)
                                    } else {
                                        continuation.resume(returning: value)
                                    }
                                }
                            } catch {
                                switch self.completeJob(id: jobID, succeeded: false) {
                                case .ignore:
                                    return
                                case .resume(let overrideError):
                                    continuation.resume(throwing: overrideError ?? error)
                                }
                            }
                        }
                    },
                    failBeforeStart: { error in
                        continuation.resume(throwing: error)
                    },
                    diagnosticSink: diagnosticSink
                )
                activeJob = job
                log(
                    job,
                    "request started continuedEligible=\(continuedProcessingPolicy == .automatic && isContinuedProcessingAvailable)"
                )

                if Task.isCancelled {
                    cancelJob(id: jobID, error: CancellationError())
                } else if !submitContinuedTaskIfPossible(for: job) {
                    startWithShortBackgroundTime(job)
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelJob(id: jobID, error: CancellationError())
            }
        })
    }

    private func startWithShortBackgroundTime(_ job: Job) {
        guard activeJob === job, !job.started, !job.completed else { return }
        job.launchTimeoutTask?.cancel()
        job.launchTimeoutTask = nil
        job.executionMode = .shortAllowance
        log(job, "short background allowance selected")
        let jobID = job.id
        job.shortTaskToken = shortTaskManager.beginTask(
            name: "HLS download and MP4 composition"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelJob(id: jobID, error: BackgroundExecutionError.expired)
            }
        }
        start(job)
    }

    private func start(_ job: Job) {
        guard activeJob === job, !job.started, !job.completed else { return }
        job.started = true
        let reporter = BackgroundExecutionProgressReporter { [weak self] update in
            await self?.updateProgress(for: job.id, update: update)
        }
        job.workTask = job.startWork(reporter)
    }

    private func cancelJob(id: UUID, error: Error) {
        guard let job = activeJob, job.id == id, !job.completed else { return }
        if error as? BackgroundExecutionError == .expired {
            log(job, "execution expired; cancelling work mode=\(job.executionMode.rawValue)")
        } else {
            log(job, "cancellation requested mode=\(job.executionMode.rawValue)")
        }
        if job.overrideError == nil { job.overrideError = error }
        if job.started {
            job.workTask?.cancel()
        } else {
            cancelPendingContinuedTaskIfAvailable(job)
            job.completed = true
            job.launchTimeoutTask?.cancel()
            activeJob = nil
            job.failBeforeStart(error)
        }
    }

    private func completeJob(id: UUID, succeeded: Bool) -> CompletionDecision {
        guard let job = activeJob, job.id == id, !job.completed else { return .ignore }
        job.completed = true
        job.launchTimeoutTask?.cancel()
        job.launchTimeoutTask = nil
        if let token = job.shortTaskToken {
            shortTaskManager.endTask(token)
            job.shortTaskToken = nil
        }
        completeContinuedTaskIfAvailable(job, succeeded: succeeded && job.overrideError == nil)
        log(
            job,
            "operation completed success=\(succeeded && job.overrideError == nil) mode=\(job.executionMode.rawValue)"
        )
        job.workTask = nil
        activeJob = nil
        return .resume(overrideError: job.overrideError)
    }

    private func updateProgress(
        for jobID: UUID,
        update: BackgroundExecutionProgressUpdate
    ) {
        guard let job = activeJob, job.id == jobID, !job.completed else { return }
        updateContinuedTaskIfAvailable(job, update: update)
    }

    @available(iOS 26.0, *)
    private func submitContinuedTask(for job: Job) -> Bool {
        let jobID = job.id
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: job.taskIdentifier,
            using: .main
        ) { [weak self] task in
            // The scheduler invokes this handler on the queue supplied above. Keep the
            // non-Sendable BGTask on that queue instead of capturing it in a new Task.
            MainActor.assumeIsolated {
                guard #available(iOS 26.0, *),
                      let continuedTask = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self?.accept(continuedTask, expectedJobID: jobID)
            }
        }
        guard registered else {
            log(job, "continued registration unavailable; falling back")
            return false
        }
        log(job, "continued launch handler registered")
        let request = BGContinuedProcessingTaskRequest(
            identifier: job.taskIdentifier,
            title: job.title,
            subtitle: job.subtitle
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log(job, "continued request submission failed; falling back")
            return false
        }
        log(job, "continued request submitted")

        job.launchTimeoutTask = Task { @MainActor [weak self, weak job] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, let job,
                  self.activeJob === job, !job.started, !job.completed else {
                return
            }
            self.log(job, "continued task start timed out; falling back")
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: job.taskIdentifier)
            self.startWithShortBackgroundTime(job)
        }
        return true
    }

    private func submitContinuedTaskIfPossible(for job: Job) -> Bool {
        guard continuedProcessingPolicy == .automatic else { return false }
        if #available(iOS 26.0, *) {
            return submitContinuedTask(for: job)
        }
        return false
    }

    @available(iOS 26.0, *)
    private func accept(_ task: BGContinuedProcessingTask, expectedJobID: UUID) {
        guard let job = activeJob,
              job.id == expectedJobID,
              !job.started,
              !job.completed else {
            task.setTaskCompleted(success: false)
            return
        }
        job.launchTimeoutTask?.cancel()
        job.launchTimeoutTask = nil
        job.executionMode = .continued
        job.continuedTask = task
        log(job, "continued task accepted")
        task.progress.totalUnitCount = 1_000
        task.progress.completedUnitCount = 0
        let jobID = job.id
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelJob(id: jobID, error: BackgroundExecutionError.expired)
            }
        }
        start(job)
    }

    private func cancelPendingContinuedTaskIfAvailable(_ job: Job) {
        guard continuedProcessingPolicy == .automatic else { return }
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: job.taskIdentifier)
        }
    }

    private func updateContinuedTaskIfAvailable(
        _ job: Job,
        update: BackgroundExecutionProgressUpdate
    ) {
        if #available(iOS 26.0, *),
           let task = job.continuedTask as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = update.totalUnitCount
            task.progress.completedUnitCount = update.completedUnitCount
            if let subtitle = update.subtitle, !subtitle.isEmpty {
                task.updateTitle(job.title, subtitle: String(subtitle.prefix(160)))
            }
        }
    }

    private func completeContinuedTaskIfAvailable(_ job: Job, succeeded: Bool) {
        if #available(iOS 26.0, *),
           let task = job.continuedTask as? BGContinuedProcessingTask {
            if succeeded {
                task.progress.completedUnitCount = max(1, task.progress.totalUnitCount)
            }
            task.expirationHandler = nil
            task.setTaskCompleted(success: succeeded)
            job.continuedTask = nil
        }
    }

    private var isContinuedProcessingAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private func log(_ job: Job, _ message: String) {
        job.diagnosticSink?(DiagnosticEvent(category: "background", message: message))
    }
}
