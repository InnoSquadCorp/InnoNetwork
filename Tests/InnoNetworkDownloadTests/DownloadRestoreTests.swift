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
}
