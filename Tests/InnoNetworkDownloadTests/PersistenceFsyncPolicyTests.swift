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
}


private actor FailingUpsertDownloadTaskStore: DownloadTaskStore {
    func upsert(id: String, url: URL, destinationURL: URL, resumeData: Data?) async throws {
        throw PersistenceTestError.upsertFailed
    }

    func updateResumeData(id: String, resumeData: Data?) async throws {}

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

        let persistence = DownloadTaskPersistence(
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
        let sessionDirectory = persistenceRoot.appendingPathComponent(sessionIdentifier, isDirectory: true)
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

        _ = DownloadTaskPersistence(
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

    @Test(".onCheckpoint policy fsyncs parent directory after checkpoint rename")
    func onCheckpointPolicyFsyncsParentDirectoryAfterCheckpointRename() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-fsync-checkpoint-dir-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let recorder = FsyncCallRecorder()
        let persistence = DownloadTaskPersistence(
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
