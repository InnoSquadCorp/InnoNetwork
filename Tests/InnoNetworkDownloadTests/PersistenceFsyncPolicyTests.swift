import Foundation
import Darwin
import InnoNetwork
import Testing
@testable import InnoNetworkDownload


private func failFsyncWithEIO(_: Int32) -> Int32 {
    errno = EIO
    return -1
}


private enum PersistenceTestError: Error {
    case upsertFailed
}


private actor FailingUpsertDownloadTaskStore: DownloadTaskStore {
    func upsert(id: String, url: URL, destinationURL: URL) async throws {
        throw PersistenceTestError.upsertFailed
    }

    func remove(id: String) async throws {}

    func record(forID id: String) async -> DownloadTaskPersistence.Record? {
        nil
    }

    func allRecords() async -> [DownloadTaskPersistence.Record] {
        []
    }

    func id(forURL url: URL?) async -> String? {
        nil
    }

    func prune(keeping ids: Set<String>) async throws {}
}


@Suite("Persistence Fsync Policy Tests")
struct PersistenceFsyncPolicyTests {

    @Test("Default DownloadConfiguration uses .onCheckpoint")
    func defaultIsOnCheckpoint() {
        let configuration = DownloadConfiguration()
        #expect(configuration.persistenceFsyncPolicy == .onCheckpoint)
    }

    @Test("Advanced builder propagates the override")
    func advancedBuilderRoundTrips() {
        let always = DownloadConfiguration.advanced(
            sessionIdentifier: "test.fsync.always.\(UUID().uuidString)"
        ) { builder in
            builder.persistenceFsyncPolicy = .always
        }
        #expect(always.persistenceFsyncPolicy == .always)

        let never = DownloadConfiguration.advanced(
            sessionIdentifier: "test.fsync.never.\(UUID().uuidString)"
        ) { builder in
            builder.persistenceFsyncPolicy = .never
        }
        #expect(never.persistenceFsyncPolicy == .never)
    }

    @Test("All three policies persist data round-trip through the actor",
          arguments: [
            DownloadConfiguration.PersistenceFsyncPolicy.always,
            .onCheckpoint,
            .never,
          ])
    func policyRoundTrip(policy: DownloadConfiguration.PersistenceFsyncPolicy) async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-fsync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let persistence = DownloadTaskPersistence(
            sessionIdentifier: "test.fsync.\(UUID().uuidString)",
            baseDirectoryURL: baseDirectory,
            fsyncPolicy: policy
        )

        let id = UUID().uuidString
        let url = URL(string: "https://example.invalid/file.zip")!
        let destination = baseDirectory.appendingPathComponent("file.zip")
        try await persistence.upsert(id: id, url: url, destinationURL: destination)

        let record = await persistence.record(forID: id)
        #expect(record?.id == id)
        #expect(record?.url == url)
        #expect(record?.destinationURL == destination)
    }

    @Test("PersistenceFsyncPolicy is Equatable across cases")
    func equality() {
        #expect(DownloadConfiguration.PersistenceFsyncPolicy.always == .always)
        #expect(DownloadConfiguration.PersistenceFsyncPolicy.onCheckpoint == .onCheckpoint)
        #expect(DownloadConfiguration.PersistenceFsyncPolicy.never == .never)
        #expect(DownloadConfiguration.PersistenceFsyncPolicy.always != .never)
    }

    @Test(".always policy surfaces append fsync failures")
    func alwaysPolicyThrowsWhenAppendFsyncFails() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-fsync-always-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let persistence = DownloadTaskPersistence(
            sessionIdentifier: "test.fsync.always.fail.\(UUID().uuidString)",
            baseDirectoryURL: baseDirectory,
            fsyncPolicy: .always,
            fsync: failFsyncWithEIO
        )

        do {
            try await persistence.upsert(
                id: "task",
                url: URL(string: "https://example.invalid/file.zip")!,
                destinationURL: baseDirectory.appendingPathComponent("file.zip")
            )
            Issue.record("Expected append fsync failure to throw")
        } catch let error as POSIXError {
            #expect(error.code == .EIO)
        } catch {
            Issue.record("Expected POSIXError.EIO, got \(error)")
        }
    }

    @Test(".onCheckpoint policy surfaces checkpoint fsync failures")
    func onCheckpointPolicyThrowsWhenCheckpointFsyncFails() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-fsync-checkpoint-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let persistence = DownloadTaskPersistence(
            sessionIdentifier: "test.fsync.checkpoint.fail.\(UUID().uuidString)",
            baseDirectoryURL: baseDirectory,
            fsyncPolicy: .onCheckpoint,
            fsync: failFsyncWithEIO
        )

        let url = URL(string: "https://example.invalid/file.zip")!
        for index in 0..<999 {
            try await persistence.upsert(
                id: "task-\(index)",
                url: url,
                destinationURL: baseDirectory.appendingPathComponent("file-\(index).zip")
            )
        }

        do {
            try await persistence.upsert(
                id: "task-999",
                url: url,
                destinationURL: baseDirectory.appendingPathComponent("file-999.zip")
            )
            Issue.record("Expected checkpoint fsync failure to throw")
        } catch let error as POSIXError {
            #expect(error.code == .EIO)
        } catch {
            Issue.record("Expected POSIXError.EIO, got \(error)")
        }
    }

    @Test("Download start fails without creating URLSession task when persistence upsert fails")
    func downloadStartFailsWithoutTransportWhenPersistenceUpsertFails() async throws {
        let identifier = "test.fsync.start.fail.\(UUID().uuidString)"
        let configuration = DownloadConfiguration(sessionIdentifier: identifier)
        let stubSession = StubDownloadURLSession()
        let callbacks = DownloadSessionDelegateCallbacks()
        let backgroundCompletionStore = BackgroundCompletionStore()
        let delegate = DownloadSessionDelegate(
            callbacks: callbacks,
            backgroundCompletionStore: backgroundCompletionStore
        )
        let manager = try DownloadManager(
            configuration: configuration,
            persistence: DownloadTaskPersistence(store: FailingUpsertDownloadTaskStore()),
            urlSession: stubSession,
            delegate: delegate,
            callbacks: callbacks,
            backgroundCompletionStore: backgroundCompletionStore
        )

        let task = await manager.download(
            url: URL(string: "https://example.invalid/file.zip")!,
            to: FileManager.default.temporaryDirectory.appendingPathComponent("never-started-\(UUID().uuidString).zip")
        )

        #expect(await task.state == .failed)
        switch await task.error {
        case .fileSystemError:
            break
        default:
            Issue.record("Expected DownloadError.fileSystemError, got \(String(describing: await task.error))")
        }
        #expect(stubSession.createdTasks.isEmpty)
        #expect(stubSession.lastURL == nil)
        #expect((await manager.allTasks()).isEmpty)
    }
}
