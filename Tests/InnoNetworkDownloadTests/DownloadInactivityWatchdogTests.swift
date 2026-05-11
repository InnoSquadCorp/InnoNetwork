import Foundation
import Testing

@testable import InnoNetwork
@testable import InnoNetworkDownload

@Suite("Download Inactivity Watchdog Tests")
struct DownloadInactivityWatchdogTests {

    @Test("Stalled task is cancelled after taskInactivityTimeout elapses")
    func stalledTaskIsCancelledAfterTimeout() async throws {
        let harness = try StubDownloadHarness(
            taskInactivityTimeout: .milliseconds(150),
            label: "inactivity-stall"
        )
        let task = await harness.startDownload()
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )

        // One progress event seeds `lastProgressAt`; no further progress
        // arrives, so the watchdog should observe a stall.
        harness.injectDelegateProgress(
            taskIdentifier: taskIdentifier,
            bytesWritten: 32,
            totalBytesWritten: 32,
            totalBytesExpectedToWrite: 1024
        )

        let cancelled = await waitFor(timeout: 2.0) {
            harness.stubTask.cancelCount >= 1
        }
        #expect(cancelled, "watchdog should cancel the stalled URLSession task")

        await harness.manager.shutdown()
    }

    @Test("Watchdog leaves an actively-progressing task alone")
    func activeTaskIsNotCancelledByWatchdog() async throws {
        let harness = try StubDownloadHarness(
            taskInactivityTimeout: .milliseconds(150),
            label: "inactivity-active"
        )
        let task = await harness.startDownload()
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )

        // Keep refreshing lastProgressAt at a cadence well below the
        // timeout for longer than the timeout itself.
        for tick in 0..<10 {
            harness.injectDelegateProgress(
                taskIdentifier: taskIdentifier,
                bytesWritten: 16,
                totalBytesWritten: Int64(16 * (tick + 1)),
                totalBytesExpectedToWrite: 1024
            )
            try await Task.sleep(for: .milliseconds(40))
        }

        #expect(harness.stubTask.cancelCount == 0,
                "watchdog must not cancel a task that is still making progress")

        await harness.manager.shutdown()
    }

    @Test("Watchdog is disabled when configuration sets a nil timeout")
    func watchdogStaysOffWhenTimeoutIsNil() async throws {
        let harness = try StubDownloadHarness(
            taskInactivityTimeout: nil,
            label: "inactivity-disabled"
        )
        let task = await harness.startDownload()
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )

        harness.injectDelegateProgress(
            taskIdentifier: taskIdentifier,
            bytesWritten: 8,
            totalBytesWritten: 8,
            totalBytesExpectedToWrite: 1024
        )
        try await Task.sleep(for: .milliseconds(300))

        #expect(harness.stubTask.cancelCount == 0,
                "no watchdog should run when taskInactivityTimeout is nil")

        await harness.manager.shutdown()
    }

    // MARK: - Helpers

    private func waitForRuntimeTaskIdentifier(
        manager: DownloadManager,
        task: DownloadTask,
        timeout: TimeInterval = 2.0
    ) async -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let identifier = await manager.runtimeTaskIdentifier(for: task) {
                return identifier
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private func waitFor(
        timeout: TimeInterval,
        condition: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
