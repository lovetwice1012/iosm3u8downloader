import XCTest
@testable import HLSDownloader

@MainActor
private final class FakeShortBackgroundTaskManager: ShortBackgroundTaskManaging {
    private(set) var begunNames: [String] = []
    private(set) var endedTokens: [ShortBackgroundTaskToken] = []
    private var nextToken: UInt64 = 1
    private var expirationHandlers: [ShortBackgroundTaskToken: @Sendable () -> Void] = [:]

    func beginTask(
        name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) -> ShortBackgroundTaskToken {
        let token = ShortBackgroundTaskToken(rawValue: nextToken)
        nextToken += 1
        begunNames.append(name)
        expirationHandlers[token] = expirationHandler
        return token
    }

    func endTask(_ token: ShortBackgroundTaskToken) {
        endedTokens.append(token)
        expirationHandlers[token] = nil
    }

    func expireLatest() {
        guard let token = expirationHandlers.keys.max(by: { $0.rawValue < $1.rawValue }),
              let handler = expirationHandlers[token] else {
            return
        }
        handler()
    }
}

@MainActor
final class BackgroundExecutionCoordinatorTests: XCTestCase {
    func testContinuedTaskIdentifiersUseUniqueFullyComposedSuffixes() {
        let firstJobID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondJobID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

        let first = BackgroundExecutionCoordinator.taskIdentifier(
            bundleIdentifier: "com.example.HLSDownloader",
            jobID: firstJobID
        )
        let second = BackgroundExecutionCoordinator.taskIdentifier(
            bundleIdentifier: "com.example.HLSDownloader",
            jobID: secondJobID
        )

        XCTAssertEqual(
            first,
            "com.example.HLSDownloader.continued-download.11111111222233334444555555555555"
        )
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.hasPrefix("com.example.HLSDownloader.continued-download."))
    }

    func testLegacyFallbackRunsOperationAndEndsAllowance() async throws {
        let manager = FakeShortBackgroundTaskManager()
        let coordinator = BackgroundExecutionCoordinator(
            shortTaskManager: manager,
            continuedProcessingPolicy: .disabled
        )
        let diagnostics = DiagnosticLogStore()

        let value = try await coordinator.run(
            title: "private video title",
            subtitle: "secret page title",
            diagnosticSink: diagnostics.sink
        ) { reporter in
            await reporter.report(completedUnitCount: 1, totalUnitCount: 2, subtitle: "Half")
            return 42
        }

        XCTAssertEqual(value, 42)
        XCTAssertEqual(manager.begunNames, ["HLS download and media composition"])
        XCTAssertEqual(manager.endedTokens.count, 1)
        let log = diagnostics.renderedText()
        XCTAssertTrue(log.contains("short background allowance selected"))
        XCTAssertTrue(log.contains("operation completed success=true"))
        XCTAssertFalse(log.contains("private video title"))
        XCTAssertFalse(log.contains("secret page title"))
    }

    func testLegacyExpirationCancelsOperationAndEndsAllowance() async throws {
        let manager = FakeShortBackgroundTaskManager()
        let coordinator = BackgroundExecutionCoordinator(
            shortTaskManager: manager,
            continuedProcessingPolicy: .disabled
        )
        let started = expectation(description: "operation started")

        let work = Task { @MainActor in
            try await coordinator.run(title: "Download", subtitle: "Preparing") { _ -> Int in
                started.fulfill()
                while true {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }

        await fulfillment(of: [started], timeout: 2)
        manager.expireLatest()

        do {
            _ = try await work.value
            XCTFail("expiration must fail the operation")
        } catch let error as BackgroundExecutionError {
            XCTAssertEqual(error, .expired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(manager.endedTokens.count, 1)
    }

    func testRejectsASecondOperationUntilFirstFinishes() async throws {
        let manager = FakeShortBackgroundTaskManager()
        let coordinator = BackgroundExecutionCoordinator(
            shortTaskManager: manager,
            continuedProcessingPolicy: .disabled
        )
        let started = expectation(description: "first operation started")

        let first = Task { @MainActor in
            try await coordinator.run(title: "First", subtitle: "Preparing") { _ -> Int in
                started.fulfill()
                while true {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)

        do {
            _ = try await coordinator.run(title: "Second", subtitle: "Preparing") { _ in 2 }
            XCTFail("a concurrent operation must be rejected")
        } catch let error as BackgroundExecutionError {
            XCTAssertEqual(error, .alreadyRunning)
        }

        first.cancel()
        do {
            _ = try await first.value
            XCTFail("the cancelled operation must fail")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(manager.endedTokens.count, 1)
    }

    func testDownloadProgressMapsToMonotonicSystemProgress() {
        let resolving = BackgroundExecutionProgressUpdate(
            downloadProgress: DownloadProgress(phase: .resolving, completedItems: 0, totalItems: 0)
        )
        let downloading = BackgroundExecutionProgressUpdate(
            downloadProgress: DownloadProgress(phase: .downloading, completedItems: 3, totalItems: 4)
        )
        let composing = BackgroundExecutionProgressUpdate(
            downloadProgress: DownloadProgress(phase: .composing, completedItems: 0, totalItems: 0)
        )
        let completed = BackgroundExecutionProgressUpdate(
            downloadProgress: DownloadProgress(phase: .completed, completedItems: 1, totalItems: 1)
        )

        XCTAssertLessThan(resolving.completedUnitCount, downloading.completedUnitCount)
        XCTAssertLessThan(downloading.completedUnitCount, composing.completedUnitCount)
        XCTAssertLessThan(composing.completedUnitCount, completed.completedUnitCount)
        XCTAssertEqual(completed.completedUnitCount, completed.totalUnitCount)
    }
}
