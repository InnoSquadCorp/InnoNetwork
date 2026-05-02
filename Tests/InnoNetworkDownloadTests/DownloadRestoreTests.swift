import Foundation
import Testing

@testable import InnoNetworkDownload

/// Restore-coordinator behavior verified through `StubDownloadURLSession`
/// + an in-memory `InMemoryDownloadTaskStore`. Replaces the previous real
/// URLSession + on-disk `AppendLogDownloadTaskStore` integration tests so
/// persistence pre-population is deterministic and no temp directory is
/// left behind.
@Suite("Download Restore Tests", .serialized)
struct DownloadRestoreTests {

    @Test("Fresh manager completes restore barrier and accepts new downloads")
    func freshManagerCompletesRestoreBarrier() async throws {
        let harness = try StubDownloadHarness(label: "restore-fresh")

        let task = await harness.startDownload()

        #expect(await harness.manager.task(withId: task.id) != nil)
        await harness.manager.cancel(task)
    }

    @Test("Orphaned persistence records are pruned after restore")
    func orphanedPersistenceRecordsPruned() async throws {
        let orphanRecord = DownloadTaskPersistence.Record(
            id: "orphan-task",
            url: URL(string: "https://example.invalid/orphan.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-orphan.zip")
        )
        let harness = try StubDownloadHarness(
            label: "restore-orphan",
            prepopulatedRecords: [orphanRecord]
        )

        // `waitForRestore` runs before the first `download()` returns, so
        // awaiting a no-op download guarantees restore has completed.
        let probe = await harness.startDownload()
        await harness.manager.cancel(probe)

        #expect(await harness.persistence.record(forID: "orphan-task") == nil)
    }

    @Test("Paused persisted records with resume data restore without a system task")
    func pausedRecordWithResumeDataRestores() async throws {
        let pausedID = "paused-task-\(UUID().uuidString)"
        let resumeData = Data("resume-after-relaunch".utf8)
        let pausedRecord = DownloadTaskPersistence.Record(
            id: pausedID,
            url: URL(string: "https://example.invalid/paused.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-paused.zip"),
            resumeData: resumeData
        )
        let resumedStub = StubDownloadURLTask()
        let harness = try StubDownloadHarness(
            label: "restore-paused",
            prepopulatedRecords: [pausedRecord],
            prequeuedStubs: [resumedStub]
        )

        let probe = await harness.startDownload(
            url: URL(string: "https://example.invalid/probe.zip")!
        )
        await harness.manager.cancel(probe)

        let restoredTask = try #require(await harness.manager.task(withId: pausedID))
        #expect(await restoredTask.state == .paused)
        #expect(await restoredTask.resumeData == resumeData)

        await harness.manager.resume(restoredTask)

        #expect(harness.stubSession.lastResumeData == resumeData)
        #expect(await restoredTask.resumeData == nil)
    }

    @Test("Foreign system tasks are cancelled during restore")
    func foreignSystemTasksAreCancelled() async throws {
        let foreignURL = URL(string: "https://example.invalid/foreign.zip")!
        let foreignStub = StubDownloadURLTask(
            request: URLRequest(url: foreignURL),
            initialState: .running
        )
        let harness = try StubDownloadHarness(
            label: "restore-foreign",
            preinstalledStubs: [foreignStub]
        )

        let probe = await harness.startDownload(
            url: URL(string: "https://example.invalid/probe.zip")!
        )
        await harness.manager.cancel(probe)

        #expect(foreignStub.cancelCount == 1)
    }

    @Test("Restore adopts an existing URL task whose taskDescription matches a persisted id")
    func restoreAdoptsExistingURLTask() async throws {
        let trackedID = "persisted-task-\(UUID().uuidString)"
        let trackedURL = URL(string: "https://example.invalid/persisted.zip")!
        let persistedRecord = DownloadTaskPersistence.Record(
            id: trackedID,
            url: trackedURL,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-persisted.zip")
        )
        let existingStub = StubDownloadURLTask(
            request: URLRequest(url: trackedURL),
            initialState: .running
        )
        existingStub.taskDescription = trackedID

        // Preinstall the existing task on the session so `allDownloadTasks()`
        // surfaces it to the restore coordinator *before* any
        // `makeDownloadTask(...)` call happens. Harness init performs the
        // preinstall before constructing the manager, so the restore task
        // (spawned on manager init) sees the task immediately.
        let harness = try StubDownloadHarness(
            label: "restore-adopt",
            prepopulatedRecords: [persistedRecord],
            preinstalledStubs: [existingStub]
        )

        // First `download()` call waits on the restore barrier, so once it
        // returns we know restore has finished. Issue it against a throwaway
        // URL so the persisted task stays separately registered.
        let probe = await harness.startDownload(
            url: URL(string: "https://example.invalid/probe.zip")!
        )

        let restoredTask = await harness.manager.task(withId: trackedID)
        #expect(restoredTask != nil)
        if let restoredTask {
            #expect(await restoredTask.state == .downloading)
            #expect(restoredTask.url == trackedURL)
        }

        await harness.manager.cancel(probe)
    }

    @Test("Restore barrier unblocks cancel path without state leakage")
    func restoreBarrierUnblocksCancelPath() async throws {
        let harness = try StubDownloadHarness(label: "restore-cancel")

        let task = await harness.startDownload()

        await harness.manager.cancelAll()
        #expect(await harness.manager.allTasks().isEmpty)
        _ = task
    }

    @Test("Persistence prune failure still queues missing-system-task announcement")
    func pruneFailureStillSurfacesRestoreFailure() async throws {
        let orphanID = "orphan-\(UUID().uuidString)"
        let orphanRecord = DownloadTaskPersistence.Record(
            id: orphanID,
            url: URL(string: "https://example.invalid/orphan.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-orphan.zip")
        )
        let harness = try StubDownloadHarness(
            label: "restore-prune-fail",
            prepopulatedRecords: [orphanRecord]
        )
        await harness.store.setRemoveFailure(true)

        // Make sure restore has run by issuing a probe and then awaiting the
        // event stream for the orphan task. The first subscription drains the
        // pending-restore queue.
        let probe = await harness.startDownload()
        await harness.manager.cancel(probe)

        let orphanTask = DownloadTask(
            url: orphanRecord.url,
            destinationURL: orphanRecord.destinationURL,
            id: orphanID
        )
        let stream = await harness.manager.events(for: orphanTask)
        var sawFailure = false
        for await event in stream {
            if case .failed(.restorationMissingSystemTask) = event {
                sawFailure = true
                break
            }
        }
        #expect(sawFailure)

        // Persistence record should remain (because remove threw); next
        // launch will reprocess it.
        #expect(await harness.persistence.record(forID: orphanID) != nil)
    }

    @Test("Restore failure replays to onFailed handler when set after restore")
    func restoreFailureReplaysToHandlerSubscriber() async throws {
        let orphanID = "orphan-handler-\(UUID().uuidString)"
        let orphanRecord = DownloadTaskPersistence.Record(
            id: orphanID,
            url: URL(string: "https://example.invalid/orphan-handler.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-orphan-handler.zip")
        )
        let harness = try StubDownloadHarness(
            label: "restore-handler",
            prepopulatedRecords: [orphanRecord]
        )

        // Wait for restore by issuing a probe.
        let probe = await harness.startDownload()
        await harness.manager.cancel(probe)

        let observed = ObservedFailure()
        await harness.manager.setOnFailedHandler { task, error in
            await observed.record(taskID: task.id, error: error)
        }

        // Setting the handler triggers an immediate drain of pending failures.
        let recorded = await observed.snapshot()
        let matched = recorded.contains { taskID, error in
            guard taskID == orphanID else { return false }
            if case .restorationMissingSystemTask = error { return true }
            return false
        }
        #expect(matched)
    }
}

private actor ObservedFailure {
    private var entries: [(String, DownloadError)] = []

    func record(taskID: String, error: DownloadError) {
        entries.append((taskID, error))
    }

    func snapshot() -> [(String, DownloadError)] {
        entries
    }
}
