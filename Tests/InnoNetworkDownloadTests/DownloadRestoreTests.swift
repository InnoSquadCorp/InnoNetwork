import Foundation
import Testing
@testable import InnoNetworkDownload


@Suite("Download Restore Tests")
struct DownloadRestoreTests {

    @Test("Fresh manager completes restore and accepts new downloads")
    func freshManagerCompletesRestoreBarrier() async throws {
        let config = DownloadConfiguration(
            sessionIdentifier: makeDownloadTestSessionIdentifier("restore-fresh")
        )
        let manager = try DownloadManager(configuration: config)

        let task = await manager.download(
            url: URL(string: "https://example.invalid/file.zip")!,
            to: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        )

        #expect(await manager.task(withId: task.id) != nil)
        await manager.cancel(task)
    }

    @Test("Orphaned persistence records are pruned after restore")
    func orphanedPersistenceRecordsPruned() async throws {
        let sessionIdentifier = makeDownloadTestSessionIdentifier("restore-orphan")
        let baseDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("InnoNetworkDownloadTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let persistence = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )
        await persistence.upsert(
            id: "orphan-task",
            url: URL(string: "https://example.invalid/orphan.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-orphan.zip")
        )
        #expect(await persistence.record(forID: "orphan-task") != nil)

        let config = DownloadConfiguration(sessionIdentifier: sessionIdentifier)
        let manager = try DownloadManager(configuration: config, persistence: persistence)

        let probe = await manager.download(
            url: URL(string: "https://example.invalid/probe.zip")!,
            to: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-probe.zip")
        )
        await manager.cancel(probe)

        let deadline = Date().addingTimeInterval(2.0)
        var pruned = false
        while Date() < deadline {
            if await persistence.record(forID: "orphan-task") == nil {
                pruned = true
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(pruned)
    }

    @Test("Restore barrier allows in-flight cancel to complete without state leakage")
    func restoreBarrierUnblocksCancelPath() async throws {
        let config = DownloadConfiguration(
            sessionIdentifier: makeDownloadTestSessionIdentifier("restore-cancel")
        )
        let manager = try DownloadManager(configuration: config)

        let task = await manager.download(
            url: URL(string: "https://example.invalid/file.zip")!,
            to: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        )

        await manager.cancelAll()
        #expect(await manager.allTasks().isEmpty)
        _ = task
    }
}
