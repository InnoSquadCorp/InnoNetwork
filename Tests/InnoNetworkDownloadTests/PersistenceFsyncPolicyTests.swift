import Darwin
import Foundation
import InnoNetwork
import Testing
import os

@testable import InnoNetworkDownload

private func failFsyncWithEIO(_: Int32) -> Int32 {
    errno = EIO
    return -1
}


private enum PersistenceTestError: Error {
    case upsertFailed
}


private final class FsyncCallRecorder: @unchecked Sendable {
    private struct State {
        var fileCount = 0
        var directoryCount = 0
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: .init())

    func record(_ fileDescriptor: Int32) -> Int32 {
        var metadata = stat()
        if fstat(fileDescriptor, &metadata) == 0 {
            let isDirectory = metadata.st_mode & S_IFMT == S_IFDIR
            lock.withLock { state in
                if isDirectory {
                    state.directoryCount += 1
                } else {
                    state.fileCount += 1
                }
            }
        }
        return 0
    }

    var directoryCount: Int {
        lock.withLock { $0.directoryCount }
    }

    var fileCount: Int {
        lock.withLock { $0.fileCount }
    }
}


private actor FailingUpsertDownloadTaskStore: DownloadTaskStore {
    func upsert(id: String, url: URL, destinationURL: URL, resumeData: Data?) async throws {
        throw PersistenceTestError.upsertFailed
    }

    func beginStart(
        id: String,
        url: URL,
        destinationURL: URL,
        mode: DownloadTaskPersistence.StartMode,
        retryCount: Int,
        totalRetryCount: Int
    ) async throws -> Bool {
        _ = (id, url, destinationURL, mode, retryCount, totalRetryCount)
        throw PersistenceTestError.upsertFailed
    }

    func updateResumeData(
        id: String,
        resumeData: Data?,
        lifecycle: DownloadTaskPersistence.Record.Lifecycle
    ) async throws {}

    func transitionResumeState(
        id: String,
        from expectedLifecycle: DownloadTaskPersistence.Record.Lifecycle?,
        to lifecycle: DownloadTaskPersistence.Record.Lifecycle,
        resumeData: Data?
    ) async throws -> Bool { false }

    func updateRetryState(
        id: String,
        retryCount: Int,
        totalRetryCount: Int,
        retryPlan: DownloadTaskPersistence.RetryPlan?
    ) async throws -> Bool {
        _ = (id, retryCount, totalRetryCount, retryPlan)
        throw PersistenceTestError.upsertFailed
    }

    func beginCommit(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata
    ) async throws -> Bool {
        _ = (id, metadata)
        throw PersistenceTestError.upsertFailed
    }

    func finishCommit(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata
    ) async throws -> Bool {
        _ = (id, metadata)
        throw PersistenceTestError.upsertFailed
    }

    func abandonCommit(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata?
    ) async throws -> Bool {
        _ = (id, metadata)
        throw PersistenceTestError.upsertFailed
    }

    func acknowledgeCommitOutcome(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata,
        outcome: DownloadTaskPersistence.CommitOutcome
    ) async throws -> Bool {
        _ = (id, metadata, outcome)
        throw PersistenceTestError.upsertFailed
    }

    func markTerminal(
        ids: Set<String>,
        inserting records: [DownloadTaskPersistence.Record]
    ) async throws {
        _ = (ids, records)
        throw PersistenceTestError.upsertFailed
    }

    func remove(id: String) async throws {}

    func remove(ids: Set<String>) async throws {}

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
        #expect(configuration.persistenceCompactionPolicy == .default)
    }

    @Test("Advanced builder propagates the override")
    func advancedBuilderRoundTrips() {
        let always = DownloadConfiguration.advanced(
            sessionIdentifier: "test.fsync.always.\(UUID().uuidString)"
        ) { builder in
            builder.persistenceFsyncPolicy = .always
            builder.persistenceCompactionPolicy = .init(maxEvents: 16, maxLogBytes: 4_096, tombstoneRatio: 0.5)
        }
        #expect(always.persistenceFsyncPolicy == .always)
        #expect(always.persistenceCompactionPolicy.maxEvents == 16)
        #expect(always.persistenceCompactionPolicy.maxLogBytes == 4_096)
        #expect(always.persistenceCompactionPolicy.tombstoneRatio == 0.5)

        let never = DownloadConfiguration.advanced(
            sessionIdentifier: "test.fsync.never.\(UUID().uuidString)"
        ) { builder in
            builder.persistenceFsyncPolicy = .never
        }
        #expect(never.persistenceFsyncPolicy == .never)
    }

    @Test("PersistenceCompactionPolicy clamps unsafe values")
    func compactionPolicyClamps() async {
        let policy = DownloadConfiguration.PersistenceCompactionPolicy(
            maxEvents: 0,
            maxLogBytes: 0,
            tombstoneRatio: 2
        )

        #expect(policy.maxEvents == 1)
        #expect(policy.maxLogBytes == 1)
        #expect(policy.tombstoneRatio == 1)
    }

    @Test(
        "All three policies persist data round-trip through the actor",
        arguments: [
            DownloadConfiguration.PersistenceFsyncPolicy.always,
            .onCheckpoint,
            .never,
        ])
    func policyRoundTrip(policy: DownloadConfiguration.PersistenceFsyncPolicy) async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-fsync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let persistence = try DownloadTaskPersistence(
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

    #if canImport(Darwin)
    @Test("Persistence-owned directories and files are excluded from backup")
    func persistenceOwnedPathsAreExcludedFromBackup() async throws {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("inno-persistence-protection-\(UUID().uuidString)", isDirectory: true)
        let sessionIdentifier = "test.storage-protection.\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: baseDirectory) }

        let destination = baseDirectory.appendingPathComponent("caller-owned.zip", isDirectory: false)
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: destination)
        var destinationResourceURL = destination
        var includedInBackup = URLResourceValues()
        includedInBackup.isExcludedFromBackup = false
        try destinationResourceURL.setResourceValues(includedInBackup)

        let persistence = try DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectory,
            compactionPolicy: .init(maxEvents: 1, maxLogBytes: 1, tombstoneRatio: 0)
        )
        try await persistence.upsert(
            id: "task",
            url: URL(string: "https://example.invalid/file.zip")!,
            destinationURL: destination
        )

        let persistenceRoot = baseDirectory.appendingPathComponent("InnoNetworkDownload", isDirectory: true)
        let sessionDirectory = persistenceRoot.appendingPathComponent(
            DownloadSessionStorageKey.component(for: sessionIdentifier),
            isDirectory: true
        )
        let ownedURLs = [
            persistenceRoot,
            sessionDirectory,
            sessionDirectory.appendingPathComponent("checkpoint.json", isDirectory: false),
            sessionDirectory.appendingPathComponent("events.log", isDirectory: false),
            sessionDirectory.appendingPathComponent(".lock", isDirectory: false),
        ]
        for url in ownedURLs {
            #expect(try downloadBackupExclusionIsApplied(to: url))
        }

        for originalURL in ownedURLs.dropFirst(2) {
            try removeDownloadBackupExclusion(from: originalURL)
            #expect(
                try downloadBackupExclusionIsApplied(to: originalURL) == false,
                "Backup exclusion setup was not cleared for \(originalURL.path)"
            )
        }

        _ = try DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectory
        )

        for url in ownedURLs {
            #expect(try downloadBackupExclusionIsApplied(to: url))
        }

        #expect(try downloadBackupExclusionIsApplied(to: destination) == false)
    }

    @Test("Download storage protection never follows symbolic links")
    func downloadStorageProtectionDoesNotFollowSymbolicLinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "inno-download-protection-symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        let targetURL = directory.appendingPathComponent("caller-owned.txt", isDirectory: false)
        let linkURL = directory.appendingPathComponent("download-link", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("caller".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        DownloadOwnedStorageProtection.apply(to: linkURL)

        #expect(try downloadBackupExclusionIsApplied(to: targetURL) == false)
    }
    #endif

    @Test("PersistenceFsyncPolicy is Equatable across cases")
    func equality() {
        #expect(DownloadConfiguration.PersistenceFsyncPolicy.always == .always)
        #expect(DownloadConfiguration.PersistenceFsyncPolicy.onCheckpoint == .onCheckpoint)
        #expect(DownloadConfiguration.PersistenceFsyncPolicy.never == .never)
        #expect(DownloadConfiguration.PersistenceFsyncPolicy.always != .never)
    }

    @Test("Atomic write removes its temporary file when pre-rename fsync fails")
    func atomicWriteRemovesTemporaryFileAfterFsyncFailure() throws {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("inno-atomic-write-cleanup-\(UUID().uuidString)", isDirectory: true)
        let destinationURL = baseDirectory.appendingPathComponent("checkpoint.json", isDirectory: false)
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: baseDirectory) }

        #expect(throws: POSIXError.self) {
            try AppendLogDownloadTaskStore.writeAtomically(
                data: Data("checkpoint".utf8),
                to: destinationURL,
                fileManager: fileManager,
                fsyncBeforeRename: true,
                fsync: failFsyncWithEIO
            )
        }

        let remainingNames = try fileManager.contentsOfDirectory(atPath: baseDirectory.path)
        #expect(remainingNames.contains(where: { $0.hasPrefix("checkpoint.tmp-") }) == false)
        #expect(fileManager.fileExists(atPath: destinationURL.path) == false)
    }

    @Test(".always policy surfaces append fsync failures")
    func alwaysPolicyThrowsWhenAppendFsyncFails() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-fsync-always-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let persistence = try DownloadTaskPersistence(
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

    @Test(
        "Commit CAS fsyncs append evidence regardless of the configured policy",
        arguments: [
            DownloadConfiguration.PersistenceFsyncPolicy.onCheckpoint,
            .never,
        ]
    )
    func commitCASForcesAppendFsync(
        policy: DownloadConfiguration.PersistenceFsyncPolicy
    ) async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-commit-fsync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let recorder = FsyncCallRecorder()
        let persistence = try DownloadTaskPersistence(
            sessionIdentifier: "test.commit.fsync.\(UUID().uuidString)",
            baseDirectoryURL: baseDirectory,
            fsyncPolicy: policy,
            fsync: recorder.record
        )
        let url = URL(string: "https://example.invalid/commit.bin")!
        let destinationURL = baseDirectory.appendingPathComponent("commit.bin")
        let finishID = "finish"
        let abandonID = "abandon"
        try await persistence.upsert(id: finishID, url: url, destinationURL: destinationURL)
        try await persistence.upsert(id: abandonID, url: url, destinationURL: destinationURL)
        #expect(recorder.fileCount == 0)
        #expect(recorder.directoryCount == 0)

        let finishMetadata = makeFsyncCommitMetadata(
            url: url,
            destinationURL: destinationURL,
            suffix: "finish"
        )
        #expect(try await persistence.beginCommit(id: finishID, metadata: finishMetadata))
        #expect(recorder.fileCount == 1)
        #expect(recorder.directoryCount == 1)
        #expect(try await persistence.finishCommit(id: finishID, metadata: finishMetadata))
        #expect(recorder.fileCount == 2)
        #expect(recorder.directoryCount == 2)

        let abandonMetadata = makeFsyncCommitMetadata(
            url: url,
            destinationURL: destinationURL,
            suffix: "abandon"
        )
        #expect(try await persistence.beginCommit(id: abandonID, metadata: abandonMetadata))
        #expect(recorder.fileCount == 3)
        #expect(recorder.directoryCount == 3)
        #expect(try await persistence.abandonCommit(id: abandonID, metadata: abandonMetadata))
        #expect(recorder.fileCount == 4)
        #expect(recorder.directoryCount == 4)
    }

    @Test("Crash-critical commit compaction fsyncs both append log and checkpoint")
    func commitCASForcesCheckpointFsyncDuringCompaction() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-commit-checkpoint-fsync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let recorder = FsyncCallRecorder()
        let persistence = try DownloadTaskPersistence(
            sessionIdentifier: "test.commit.checkpoint.fsync.\(UUID().uuidString)",
            baseDirectoryURL: baseDirectory,
            fsyncPolicy: .never,
            compactionPolicy: .init(
                maxEvents: 1,
                maxLogBytes: UInt64.max,
                tombstoneRatio: 1
            ),
            fsync: recorder.record
        )
        let id = "commit"
        let url = URL(string: "https://example.invalid/commit-checkpoint.bin")!
        try await persistence.upsert(
            id: id,
            url: url,
            destinationURL: baseDirectory.appendingPathComponent("commit-checkpoint.bin")
        )
        #expect(recorder.fileCount == 0)
        #expect(recorder.directoryCount == 0)

        let metadata = makeFsyncCommitMetadata(
            url: url,
            destinationURL: baseDirectory.appendingPathComponent("commit-checkpoint.bin"),
            suffix: "checkpoint"
        )
        #expect(try await persistence.beginCommit(id: id, metadata: metadata))
        #expect(recorder.fileCount == 2)
        #expect(recorder.directoryCount == 2)
    }

    @Test(".never policy still surfaces crash-critical commit fsync failures")
    func commitCASPropagatesForcedFsyncFailure() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-commit-fsync-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let persistence = try DownloadTaskPersistence(
            sessionIdentifier: "test.commit.fsync.fail.\(UUID().uuidString)",
            baseDirectoryURL: baseDirectory,
            fsyncPolicy: .never,
            fsync: failFsyncWithEIO
        )
        let id = "commit"
        let url = URL(string: "https://example.invalid/commit-failure.bin")!
        try await persistence.upsert(
            id: id,
            url: url,
            destinationURL: baseDirectory.appendingPathComponent("commit-failure.bin")
        )

        do {
            _ = try await persistence.beginCommit(
                id: id,
                metadata: makeFsyncCommitMetadata(
                    url: url,
                    destinationURL: baseDirectory.appendingPathComponent("commit-failure.bin"),
                    suffix: "failure"
                )
            )
            Issue.record("Expected crash-critical commit fsync failure to throw")
        } catch let error as POSIXError {
            #expect(error.code == .EIO)
        } catch {
            Issue.record("Expected POSIXError.EIO, got \(error)")
        }
    }

    @Test("Corrupt-log recovery keeps the source log when checkpoint fsync fails")
    func corruptLogRecoveryPreservesLogBeforeCheckpointDurability() async throws {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("inno-corrupt-log-fsync-\(UUID().uuidString)", isDirectory: true)
        let sessionIdentifier = "test.corrupt.log.fsync.\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: baseDirectory) }

        let writer = try DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectory
        )
        let destinationURL = baseDirectory.appendingPathComponent("file.zip")
        try await writer.upsert(
            id: "task-valid",
            url: URL(string: "https://example.invalid/corrupt-log.bin")!,
            destinationURL: destinationURL
        )

        let storeDirectory =
            baseDirectory
            .appendingPathComponent("InnoNetworkDownload", isDirectory: true)
            .appendingPathComponent(
                DownloadSessionStorageKey.component(for: sessionIdentifier),
                isDirectory: true
            )
        let checkpointURL = storeDirectory.appendingPathComponent("checkpoint.json")
        let logURL = storeDirectory.appendingPathComponent("events.log")
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()
        let logBefore = try Data(contentsOf: logURL)

        do {
            _ = try DownloadTaskPersistence(
                sessionIdentifier: sessionIdentifier,
                baseDirectoryURL: baseDirectory,
                fsync: failFsyncWithEIO
            )
            Issue.record("Expected recovery checkpoint fsync failure to throw")
        } catch let error as POSIXError {
            #expect(error.code == .EIO)
        } catch {
            Issue.record("Expected POSIXError.EIO, got \(error)")
        }

        #expect(fileManager.fileExists(atPath: checkpointURL.path) == false)
        #expect(try Data(contentsOf: logURL) == logBefore)
        let names = try fileManager.contentsOfDirectory(atPath: storeDirectory.path)
        #expect(names.contains(where: { $0.hasPrefix("events.corrupted-") }) == false)

        let reader = try DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectory
        )
        #expect(await reader.record(forID: "task-valid")?.destinationURL == destinationURL)
    }

    @Test(".onCheckpoint policy surfaces checkpoint fsync failures")
    func onCheckpointPolicyThrowsWhenCheckpointFsyncFails() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-fsync-checkpoint-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let persistence = try DownloadTaskPersistence(
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

    @Test(".onCheckpoint policy fsyncs parent directory after checkpoint rename")
    func onCheckpointPolicyFsyncsParentDirectoryAfterCheckpointRename() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-fsync-checkpoint-dir-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let recorder = FsyncCallRecorder()
        let persistence = try DownloadTaskPersistence(
            sessionIdentifier: "test.fsync.checkpoint.dir.\(UUID().uuidString)",
            baseDirectoryURL: baseDirectory,
            fsyncPolicy: .onCheckpoint,
            fsync: recorder.record
        )

        let url = URL(string: "https://example.invalid/file.zip")!
        for index in 0..<1_000 {
            try await persistence.upsert(
                id: "task-\(index)",
                url: url,
                destinationURL: baseDirectory.appendingPathComponent("file-\(index).zip")
            )
        }

        #expect(recorder.directoryCount >= 1)
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

private func makeFsyncCommitMetadata(
    url: URL,
    destinationURL: URL,
    suffix: String
) -> DownloadTaskPersistence.CommitMetadata {
    DownloadTaskPersistence.CommitMetadata(
        stagingKey: try! DownloadCompletionStager.stagingKey(
            forTaskID: "fsync-\(suffix)"
        ),
        originalRequestURL: url,
        currentRequestURL: url,
        destinationURL: destinationURL,
        expectedByteCount: 1,
        payloadSHA256: try! DownloadCompletionStager.stagingKey(
            forTaskID: "payload-\(suffix)"
        )
    )
}

#if canImport(Darwin)
private func downloadBackupExclusionIsApplied(to url: URL) throws -> Bool {
    #if os(macOS)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let extendedAttributesKey = FileAttributeKey(rawValue: "NSFileExtendedAttributes")
    let extendedAttributes = attributes[extendedAttributesKey] as? [String: Data]
    return extendedAttributes?["com.apple.metadata:com_apple_backup_excludeItem"] != nil
    #else
    return try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    #endif
}

private func removeDownloadBackupExclusion(from url: URL) throws {
    #if os(macOS)
    let result: Int32 = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return "com.apple.metadata:com_apple_backup_excludeItem".withCString { name in
            removexattr(path, name, 0)
        }
    }
    if result != 0 {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    #else
    var resourceURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = false
    try resourceURL.setResourceValues(values)
    #endif
}
#endif
