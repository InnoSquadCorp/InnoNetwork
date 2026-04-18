import Foundation
import Testing
@testable import InnoNetworkDownload


@Suite("Download Pause/Resume Tests")
struct DownloadPauseResumeTests {

    @Test("Pause on idle task is a no-op")
    func pauseOnIdleIsNoOp() async throws {
        let url = URL(string: "https://example.invalid/file.zip")!
        let destination = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        let freshTask = DownloadTask(url: url, destinationURL: destination)

        let config = DownloadConfiguration(sessionIdentifier: makeDownloadTestSessionIdentifier("pause-idle"))
        let manager = try DownloadManager(configuration: config)

        await manager.pause(freshTask)

        #expect(await freshTask.state == .idle)
    }

    @Test("Resume on non-paused task is a no-op")
    func resumeOnNonPausedIsNoOp() async throws {
        let url = URL(string: "https://example.invalid/file.zip")!
        let destination = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        let idleTask = DownloadTask(url: url, destinationURL: destination)

        let config = DownloadConfiguration(sessionIdentifier: makeDownloadTestSessionIdentifier("resume-idle"))
        let manager = try DownloadManager(configuration: config)

        await manager.resume(idleTask)

        #expect(await idleTask.state == .idle)
    }

    @Test("Pause transitions downloading task to paused state")
    func pauseDownloadingTaskTransitionsToPaused() async throws {
        let config = DownloadConfiguration(
            maxRetryCount: 0,
            maxTotalRetries: 0,
            retryDelay: 0,
            sessionIdentifier: makeDownloadTestSessionIdentifier("pause-downloading")
        )
        let manager = try DownloadManager(configuration: config)

        let task = await manager.download(
            url: URL(string: "https://example.invalid/file.zip")!,
            to: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        )

        _ = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))
        #expect(await waitForTaskState(task, timeout: 2.0) { $0 == .downloading })

        await manager.pause(task)

        #expect(await waitForTaskState(task, timeout: 2.0) { $0 == .paused })
        await manager.cancel(task)
    }

    @Test("Resume on paused task without resumeData falls back to fresh download")
    func resumeWithoutResumeDataFallsBackToFreshDownload() async throws {
        let config = DownloadConfiguration(
            maxRetryCount: 0,
            maxTotalRetries: 0,
            retryDelay: 0,
            sessionIdentifier: makeDownloadTestSessionIdentifier("resume-fresh")
        )
        let manager = try DownloadManager(configuration: config)

        let task = await manager.download(
            url: URL(string: "https://example.invalid/file.zip")!,
            to: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        )

        let firstIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))
        await task.updateState(.paused)
        await task.setResumeData(nil)

        await manager.resume(task)

        #expect(await waitForTaskState(task, timeout: 2.0) { $0 == .downloading || $0 == .waiting })
        let secondIdentifier = await manager.runtimeTaskIdentifier(for: task)
        #expect(secondIdentifier != nil)
        #expect(secondIdentifier != firstIdentifier)

        await manager.cancel(task)
    }

    @Test("Cancel from paused state clears runtime and sets cancelled")
    func cancelFromPausedClearsRuntime() async throws {
        let config = DownloadConfiguration(
            maxRetryCount: 0,
            maxTotalRetries: 0,
            retryDelay: 0,
            sessionIdentifier: makeDownloadTestSessionIdentifier("cancel-paused")
        )
        let manager = try DownloadManager(configuration: config)

        let task = await manager.download(
            url: URL(string: "https://example.invalid/file.zip")!,
            to: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        )

        _ = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))
        #expect(await waitForTaskState(task, timeout: 2.0) { $0 == .downloading })

        await manager.pause(task)
        #expect(await waitForTaskState(task, timeout: 2.0) { $0 == .paused })

        await manager.cancel(task)

        #expect(await task.state == .cancelled)
        #expect(await manager.task(withId: task.id) == nil)
        #expect(await manager.runtimeTaskIdentifier(for: task) == nil)
    }
}
