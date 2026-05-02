import Foundation
import Testing

@testable import InnoNetworkDownload

@Suite("Download Manager Hardening Tests")
struct DownloadManagerHardeningTests {

    @Test("shutdown() invalidates the URLSession and cancels in-flight tasks")
    func shutdownCancelsInFlightAndInvalidates() async throws {
        let harness = try StubDownloadHarness(label: "shutdown-cancel")
        _ = await harness.startDownload()

        await harness.manager.shutdown()

        #expect(harness.stubSession.didInvalidateAndCancel)
        // After shutdown, the in-flight stub task receives a cancel call so
        // the URLSession can drain.
        #expect(harness.stubTask.cancelCount >= 1)
    }

    @Test("shutdown() is idempotent")
    func shutdownIsIdempotent() async throws {
        let harness = try StubDownloadHarness(label: "shutdown-idem")
        _ = await harness.startDownload()
        await harness.manager.shutdown()
        // Second call is a no-op — must not re-invalidate or trap.
        await harness.manager.shutdown()
        #expect(harness.stubSession.didInvalidateAndCancel)
    }

    @Test("shutdown() finishes the per-task event stream so listeners observe end-of-stream")
    func shutdownFinishesEventStream() async throws {
        let harness = try StubDownloadHarness(label: "shutdown-events")
        let task = await harness.startDownload()
        let stream = await harness.manager.events(for: task)

        await harness.manager.shutdown()

        // Drain the stream — once shutdown finishes the partition the
        // iterator returns nil rather than hanging. The for-await terminating
        // is the assertion: a regression where shutdown leaves the stream
        // open would cause the test to hang and then time out.
        var observed = 0
        for await _ in stream {
            observed += 1
            if observed > 100 { break }
        }
        #expect(observed <= 100)
    }
}


@Suite("Download Persistence Hardening Tests")
struct DownloadPersistenceHardeningTests {

    @Test("id(forURL:) returns the most recently upserted task for that URL")
    func urlReverseIndexReturnsLatestUpsert() async throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-persist-hardening-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let persistence = DownloadTaskPersistence(
            sessionIdentifier: "url-index-test",
            baseDirectoryURL: baseDir
        )
        let url = URL(string: "https://example.invalid/a.bin")!
        let dest = URL(fileURLWithPath: "/tmp/a.bin")

        try await persistence.upsert(id: "first", url: url, destinationURL: dest)
        #expect(await persistence.id(forURL: url) == "first")

        // Re-upserting the same id keeps the same reverse-index entry.
        try await persistence.upsert(id: "first", url: url, destinationURL: dest, resumeData: Data([0x01]))
        #expect(await persistence.id(forURL: url) == "first")

        // Removing the record clears the reverse-index entry.
        try await persistence.remove(id: "first")
        #expect(await persistence.id(forURL: url) == nil)
    }

    @Test("id(forURL:) is rebuilt from the on-disk log on init")
    func urlReverseIndexRebuiltOnReload() async throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-persist-hardening-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let url = URL(string: "https://example.invalid/b.bin")!
        let dest = URL(fileURLWithPath: "/tmp/b.bin")

        let first = DownloadTaskPersistence(
            sessionIdentifier: "url-reload-test",
            baseDirectoryURL: baseDir
        )
        try await first.upsert(id: "persisted", url: url, destinationURL: dest)

        // Reopening the same directory must reload the reverse index.
        let reloaded = DownloadTaskPersistence(
            sessionIdentifier: "url-reload-test",
            baseDirectoryURL: baseDir
        )
        #expect(await reloaded.id(forURL: url) == "persisted")
    }

    @Test("checkpoint preserves same-URL reverse-index ordering")
    func checkpointPreservesSameURLLatestID() async throws {
        let sessionIdentifier = "url-checkpoint-order-test"
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-persist-hardening-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let compactionPolicy = DownloadConfiguration.PersistenceCompactionPolicy(
            maxEvents: 2,
            maxLogBytes: UInt64.max,
            tombstoneRatio: 1
        )
        let url = URL(string: "https://example.invalid/shared.bin")!
        let firstDest = URL(fileURLWithPath: "/tmp/first.bin")
        let secondDest = URL(fileURLWithPath: "/tmp/second.bin")

        let writer = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDir,
            compactionPolicy: compactionPolicy
        )
        try await writer.upsert(id: "older", url: url, destinationURL: firstDest)
        try await writer.upsert(id: "newer", url: url, destinationURL: secondDest)

        let checkpointURL =
            baseDir
            .appendingPathComponent("InnoNetworkDownload", isDirectory: true)
            .appendingPathComponent(sessionIdentifier, isDirectory: true)
            .appendingPathComponent("checkpoint.json", isDirectory: false)
        let checkpointText = try String(contentsOf: checkpointURL, encoding: .utf8)
        #expect(checkpointText.contains("orderedRecordIDs"))

        let reloaded = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDir,
            compactionPolicy: compactionPolicy
        )
        #expect(await reloaded.id(forURL: url) == "newer")
    }
}
