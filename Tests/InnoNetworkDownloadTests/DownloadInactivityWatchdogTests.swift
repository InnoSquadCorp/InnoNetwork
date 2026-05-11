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

    @Test("Resume after long pause does not trigger watchdog cancel on the fresh attempt")
    func resumeAfterPauseDoesNotImmediatelyCancel() async throws {
        let resumedStub = StubDownloadURLTask()
        let harness = try StubDownloadHarness(
            taskInactivityTimeout: .milliseconds(150),
            label: "inactivity-pause-resume",
            prequeuedStubs: [resumedStub]
        )
        let resumeData = Data("resume-payload".utf8)
        harness.stubTask.scriptCancelResumeData(resumeData)

        let task = await harness.startDownload()
        let initialIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )

        // Seed `lastProgressAt` with a real timestamp, then pause for
        // *longer than the inactivity timeout*. Without resetting the
        // timestamp on resume, the next watchdog tick would compare
        // `now` to the pre-pause instant and cancel the resumed task
        // before its first progress callback arrives.
        harness.injectDelegateProgress(
            taskIdentifier: initialIdentifier,
            bytesWritten: 32,
            totalBytesWritten: 32,
            totalBytesExpectedToWrite: 1024
        )
        await harness.manager.pause(task)
        try await Task.sleep(for: .milliseconds(300))

        await harness.manager.resume(task)

        // Give the watchdog at least one tick post-resume (cadence is
        // `timeout / 2 == 75ms`) to attempt a stale cancellation.
        try await Task.sleep(for: .milliseconds(100))

        #expect(
            resumedStub.cancelCount == 0,
            "watchdog must not cancel a freshly resumed task before its first progress callback"
        )

        await harness.manager.cancel(task)
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
