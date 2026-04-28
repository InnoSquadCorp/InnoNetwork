import Foundation
import Testing

@testable import InnoNetworkDownload

/// Pause / resume lifecycle verified through `StubDownloadURLSession`.
/// Each test drives state transitions by injecting synthetic delegate
/// callbacks; no `.invalid` URL races and no wall-clock polling. Serialized
/// because pause→resume transitions and the manager's `waitForRestore`
/// barrier share cooperative pool slots with the concurrent retry suite.
@Suite("Download Pause/Resume Tests", .serialized)
struct DownloadPauseResumeTests {

    @Test("Pause on idle task is a no-op")
    func pauseOnIdleIsNoOp() async throws {
        let harness = try StubDownloadHarness(label: "pause-idle")
        let task = DownloadTask(
            url: URL(string: "https://example.invalid/file.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        )

        await harness.manager.pause(task)

        #expect(await task.state == .idle)
    }

    @Test("Resume on non-paused task is a no-op")
    func resumeOnNonPausedIsNoOp() async throws {
        let harness = try StubDownloadHarness(label: "resume-idle")
        let task = DownloadTask(
            url: URL(string: "https://example.invalid/file.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        )

        await harness.manager.resume(task)

        #expect(await task.state == .idle)
    }

    @Test("Pause transitions downloading task to paused and captures resumeData")
    func pauseDownloadingTaskTransitionsToPaused() async throws {
        let harness = try StubDownloadHarness(label: "pause-downloading")
        let expectedResumeData = Data("resume-stub".utf8)
        harness.stubTask.scriptCancelResumeData(expectedResumeData)

        let task = await harness.startDownload()

        _ = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task,
                timeout: 5.0
            ))
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .downloading })

        await harness.manager.pause(task)

        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .paused })
        #expect(harness.stubTask.cancelByProducingResumeDataCount == 1)
        #expect(await task.resumeData == expectedResumeData)
        await harness.manager.cancel(task)
    }

    @Test("Resume from paused with resumeData creates a new task via withResumeData:")
    func resumeFromPausedUsesResumeData() async throws {
        let resumedStub = StubDownloadURLTask()
        let harness = try StubDownloadHarness(
            label: "resume-with-data",
            prequeuedStubs: [resumedStub]
        )
        let resumeData = Data("resume-payload".utf8)
        harness.stubTask.scriptCancelResumeData(resumeData)

        let task = await harness.startDownload()
        _ = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task,
                timeout: 5.0
            ))
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .downloading })

        await harness.manager.pause(task)
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .paused })

        await harness.manager.resume(task)

        #expect(harness.stubSession.lastResumeData == resumeData)
        #expect(
            await waitForTaskState(task, timeout: 5.0) {
                $0 == .downloading || $0 == .waiting
            })
        let secondIdentifier = await harness.manager.runtimeTaskIdentifier(for: task)
        #expect(secondIdentifier == resumedStub.taskIdentifier)
        await harness.manager.cancel(task)
    }

    @Test("Resume without resumeData falls back to fresh makeDownloadTask(with:)")
    func resumeWithoutResumeDataFallsBackToFreshDownload() async throws {
        let freshStub = StubDownloadURLTask()
        let harness = try StubDownloadHarness(
            label: "resume-fresh",
            prequeuedStubs: [freshStub]
        )
        harness.stubTask.scriptCancelResumeData(nil)

        let task = await harness.startDownload()
        _ = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task,
                timeout: 5.0
            ))
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .downloading })

        await harness.manager.pause(task)
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .paused })
        await task.setResumeData(nil)

        await harness.manager.resume(task)

        #expect(harness.stubSession.lastResumeData == nil)
        #expect(
            await waitForTaskState(task, timeout: 5.0) {
                $0 == .downloading || $0 == .waiting
            })
        let secondIdentifier = await harness.manager.runtimeTaskIdentifier(for: task)
        #expect(secondIdentifier == freshStub.taskIdentifier)
        await harness.manager.cancel(task)
    }

    @Test("Cancel from paused state clears runtime registration")
    func cancelFromPausedClearsRuntime() async throws {
        let harness = try StubDownloadHarness(label: "cancel-paused")
        harness.stubTask.scriptCancelResumeData(Data("cancel-after-pause".utf8))

        let task = await harness.startDownload()
        _ = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task,
                timeout: 5.0
            ))
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .downloading })

        await harness.manager.pause(task)
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .paused })

        await harness.manager.cancel(task)

        #expect(await task.state == .cancelled)
        #expect(await harness.manager.task(withId: task.id) == nil)
        #expect(await harness.manager.runtimeTaskIdentifier(for: task) == nil)
    }
}
