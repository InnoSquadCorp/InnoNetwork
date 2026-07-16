import Darwin
import Foundation
import Testing
import os

@testable import InnoNetworkDownload

@Suite("Download Persistence Symlink Hardening Tests", .serialized)
struct DownloadPersistenceSymlinkTests {
    @Test("A caller-provided base symlink remains a supported trusted anchor")
    func callerBaseSymlinkIsCanonicalized() async throws {
        let fileManager = FileManager.default
        let fixture = makeFixture(prefix: "base-link")
        defer { fixture.remove() }
        try fileManager.createDirectory(at: fixture.outside, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: fixture.base,
            withDestinationURL: fixture.outside
        )

        let persistence = try DownloadTaskPersistence(
            sessionIdentifier: fixture.sessionIdentifier,
            baseDirectoryURL: fixture.base
        )
        try await persistence.upsert(
            id: "task",
            url: URL(string: "https://example.invalid/base-link.bin")!,
            destinationURL: fixture.parent.appendingPathComponent("destination.bin")
        )

        let realSession = sessionDirectory(
            base: fixture.outside,
            sessionIdentifier: fixture.sessionIdentifier
        )
        #expect(fileManager.fileExists(atPath: realSession.appendingPathComponent("events.log").path))
    }

    @Test("A persistence-root symlink is rejected without touching its target")
    func persistenceRootSymlinkCannotEscape() throws {
        let fileManager = FileManager.default
        let fixture = makeFixture(prefix: "root-link")
        defer { fixture.remove() }
        try fileManager.createDirectory(at: fixture.base, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fixture.outside, withIntermediateDirectories: true)
        let sentinel = fixture.outside.appendingPathComponent("sentinel")
        try Data("outside".utf8).write(to: sentinel)
        try fileManager.createSymbolicLink(
            at: fixture.base.appendingPathComponent("InnoNetworkDownload"),
            withDestinationURL: fixture.outside
        )

        #expect(throws: (any Error).self) {
            _ = try DownloadTaskPersistence(
                sessionIdentifier: fixture.sessionIdentifier,
                baseDirectoryURL: fixture.base
            )
        }
        #expect(try Data(contentsOf: sentinel) == Data("outside".utf8))
        #expect(fileManager.fileExists(atPath: fixture.outside.appendingPathComponent(".lock").path) == false)
        #expect(
            fileManager.fileExists(atPath: fixture.outside.appendingPathComponent("events.log").path) == false
        )
    }

    @Test("A session-directory symlink is rejected without touching its target")
    func sessionDirectorySymlinkCannotEscape() throws {
        let fileManager = FileManager.default
        let fixture = makeFixture(prefix: "session-link")
        defer { fixture.remove() }
        let root = fixture.base.appendingPathComponent("InnoNetworkDownload", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fixture.outside, withIntermediateDirectories: true)
        let sentinel = fixture.outside.appendingPathComponent("sentinel")
        try Data("outside".utf8).write(to: sentinel)
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent(
                DownloadSessionStorageKey.component(for: fixture.sessionIdentifier),
                isDirectory: true
            ),
            withDestinationURL: fixture.outside
        )

        #expect(throws: (any Error).self) {
            _ = try DownloadTaskPersistence(
                sessionIdentifier: fixture.sessionIdentifier,
                baseDirectoryURL: fixture.base
            )
        }
        #expect(try Data(contentsOf: sentinel) == Data("outside".utf8))
        #expect(fileManager.fileExists(atPath: fixture.outside.appendingPathComponent(".lock").path) == false)
    }

    @Test(
        "Persistence-file symlinks are rejected without following their targets",
        arguments: [".lock", "checkpoint.json", "events.log"]
    )
    func persistenceFileSymlinkCannotEscape(fileName: String) throws {
        let fileManager = FileManager.default
        let fixture = makeFixture(prefix: "file-link-\(fileName.replacingOccurrences(of: ".", with: "-"))")
        defer { fixture.remove() }
        let session = sessionDirectory(
            base: fixture.base,
            sessionIdentifier: fixture.sessionIdentifier
        )
        try fileManager.createDirectory(at: session, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fixture.outside, withIntermediateDirectories: true)
        let sentinel = fixture.outside.appendingPathComponent("sentinel")
        let sentinelData = Data("outside-\(fileName)".utf8)
        try sentinelData.write(to: sentinel)
        try fileManager.createSymbolicLink(
            at: session.appendingPathComponent(fileName),
            withDestinationURL: sentinel
        )

        #expect(throws: (any Error).self) {
            _ = try DownloadTaskPersistence(
                sessionIdentifier: fixture.sessionIdentifier,
                baseDirectoryURL: fixture.base
            )
        }
        #expect(try Data(contentsOf: sentinel) == sentinelData)
        #expect(
            (try fileManager.contentsOfDirectory(atPath: session.path))
                .contains(where: { $0.contains(".corrupted-") }) == false
        )
    }

    @Test(
        "Persistence-file hard links are rejected without mutating the shared inode",
        arguments: [".lock", "checkpoint.json", "events.log"]
    )
    func persistenceFileHardLinkCannotEscape(fileName: String) throws {
        let fileManager = FileManager.default
        let fixture = makeFixture(prefix: "file-hard-link-\(fileName.replacingOccurrences(of: ".", with: "-"))")
        defer { fixture.remove() }
        let session = sessionDirectory(
            base: fixture.base,
            sessionIdentifier: fixture.sessionIdentifier
        )
        try fileManager.createDirectory(at: session, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fixture.outside, withIntermediateDirectories: true)
        let sentinel = fixture.outside.appendingPathComponent("sentinel")
        let sentinelData = Data("outside-hard-link-\(fileName)".utf8)
        try sentinelData.write(to: sentinel)
        let managedEntry = session.appendingPathComponent(fileName)
        try fileManager.linkItem(at: sentinel, to: managedEntry)

        #expect(throws: (any Error).self) {
            _ = try DownloadTaskPersistence(
                sessionIdentifier: fixture.sessionIdentifier,
                baseDirectoryURL: fixture.base
            )
        }
        #expect(try Data(contentsOf: sentinel) == sentinelData)
        #expect(try Data(contentsOf: managedEntry) == sentinelData)
    }

    @Test("A quarantine rename failure preserves the exact corrupt log")
    func quarantineFailurePreservesCorruptLog() async throws {
        let fileManager = FileManager.default
        let fixture = makeFixture(prefix: "quarantine-failure")
        defer { fixture.remove() }
        let writer = try DownloadTaskPersistence(
            sessionIdentifier: fixture.sessionIdentifier,
            baseDirectoryURL: fixture.base
        )
        try await writer.upsert(
            id: "task",
            url: URL(string: "https://example.invalid/quarantine.bin")!,
            destinationURL: fixture.parent.appendingPathComponent("destination.bin")
        )

        let session = sessionDirectory(
            base: fixture.base,
            sessionIdentifier: fixture.sessionIdentifier
        )
        let logURL = session.appendingPathComponent("events.log")
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()
        let corruptLog = try Data(contentsOf: logURL)

        do {
            _ = try DownloadTaskPersistence(
                sessionIdentifier: fixture.sessionIdentifier,
                baseDirectoryURL: fixture.base,
                fileOperations: .init(renameEntry: { descriptor, oldName, newName in
                    if oldName == "events.log", newName.contains(".corrupted-") {
                        errno = EIO
                        return -1
                    }
                    return oldName.withCString { oldPointer in
                        newName.withCString { newPointer in
                            Darwin.renameat(descriptor, oldPointer, descriptor, newPointer)
                        }
                    }
                })
            )
            Issue.record("Expected quarantine rename failure to fail initialization")
        } catch let error as POSIXError {
            #expect(error.code == .EIO)
        } catch {
            Issue.record("Expected POSIXError.EIO, got \(error)")
        }

        #expect(try Data(contentsOf: logURL) == corruptLog)
        let names = try fileManager.contentsOfDirectory(atPath: session.path)
        #expect(names.contains(where: { $0.hasPrefix("events.corrupted-") }) == false)
    }

    @Test("A FIFO persistence entry is rejected without waiting for a peer")
    func fifoEntryCannotBlockPersistenceOpen() async throws {
        let fixture = makeFixture(prefix: "fifo")
        defer { fixture.remove() }
        let session = sessionDirectory(
            base: fixture.base,
            sessionIdentifier: fixture.sessionIdentifier
        )
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let fifoURL = session.appendingPathComponent("events.log")
        #expect(mkfifo(fifoURL.path, S_IRUSR | S_IWUSR) == 0)
        let directoryDescriptor = open(session.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(directoryDescriptor >= 0)
        guard directoryDescriptor >= 0 else { return }
        defer { close(directoryDescriptor) }

        let inspection = Task.detached {
            do {
                let opened = try AppendLogDownloadTaskStore.openRegularFile(
                    directoryDescriptor: directoryDescriptor,
                    name: "events.log",
                    flags: O_RDONLY
                )
                close(opened.descriptor)
                return false
            } catch let error as POSIXError {
                return error.code == .EINVAL
            } catch {
                return false
            }
        }

        let completedBeforeTimeout = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await inspection.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(250))
                return false
            }
            let completed = await group.next() ?? false
            if !completed {
                // Unblock an implementation that accidentally opens the FIFO
                // without O_NONBLOCK so this regression test never hangs CI.
                let peer = open(fifoURL.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
                if peer >= 0 { close(peer) }
            }
            group.cancelAll()
            return completed
        }

        #expect(completedBeforeTimeout)
        #expect(await inspection.value)
    }

    @Test("A parent swap after session open cannot redirect authoritative I/O")
    func parentSwapCannotRedirectOpenSessionDescriptor() async throws {
        let fileManager = FileManager.default
        let fixture = makeFixture(prefix: "parent-swap")
        defer { fixture.remove() }
        try fileManager.createDirectory(at: fixture.base, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fixture.outside, withIntermediateDirectories: true)
        let outsideLog = fixture.outside.appendingPathComponent("events.log")
        let sentinelData = Data("outside-sentinel".utf8)
        try sentinelData.write(to: outsideLog)
        let movedSession = fixture.parent.appendingPathComponent("anchored-session", isDirectory: true)
        let swap = ParentSwapRecorder(movedSession: movedSession, outside: fixture.outside)

        let persistence = try DownloadTaskPersistence(
            sessionIdentifier: fixture.sessionIdentifier,
            baseDirectoryURL: fixture.base,
            fileOperations: .init(didOpenSessionDirectory: swap.perform)
        )
        #expect(swap.errorDescription == nil)
        try await persistence.upsert(
            id: "task",
            url: URL(string: "https://example.invalid/parent-swap.bin")!,
            destinationURL: fixture.parent.appendingPathComponent("destination.bin")
        )

        #expect(try Data(contentsOf: outsideLog) == sentinelData)
        #expect(fileManager.fileExists(atPath: fixture.outside.appendingPathComponent(".lock").path) == false)
        #expect(fileManager.fileExists(atPath: movedSession.appendingPathComponent("events.log").path))
        #expect(fileManager.fileExists(atPath: movedSession.appendingPathComponent(".lock").path))
    }

    @Test("A temporary-entry swap before rename is rejected without touching its target")
    func temporaryEntrySwapCannotRedirectAtomicReplacement() async throws {
        let fileManager = FileManager.default
        let fixture = makeFixture(prefix: "temp-swap")
        defer { fixture.remove() }
        try fileManager.createDirectory(at: fixture.outside, withIntermediateDirectories: true)
        let sentinel = fixture.outside.appendingPathComponent("sentinel")
        let sentinelData = Data("outside-sentinel".utf8)
        try sentinelData.write(to: sentinel)
        let swap = TemporaryEntrySwapRecorder(target: sentinel)

        let persistence = try DownloadTaskPersistence(
            sessionIdentifier: fixture.sessionIdentifier,
            baseDirectoryURL: fixture.base,
            compactionPolicy: .init(maxEvents: 1, maxLogBytes: .max, tombstoneRatio: 1),
            fileOperations: .init(
                temporaryName: { _ in "checkpoint.tmp-race" },
                willRenameTemporaryEntry: swap.perform
            )
        )

        do {
            try await persistence.upsert(
                id: "task",
                url: URL(string: "https://example.invalid/temp-swap.bin")!,
                destinationURL: fixture.parent.appendingPathComponent("destination.bin")
            )
            Issue.record("Expected the temporary inode replacement to abort checkpoint installation")
        } catch let error as POSIXError {
            #expect(error.code == .EBUSY)
        } catch {
            Issue.record("Expected POSIXError.EBUSY, got \(error)")
        }

        #expect(swap.didSwap)
        #expect(try Data(contentsOf: sentinel) == sentinelData)
        let session = sessionDirectory(
            base: fixture.base,
            sessionIdentifier: fixture.sessionIdentifier
        )
        #expect(fileManager.fileExists(atPath: session.appendingPathComponent("checkpoint.json").path) == false)
        #expect(fileManager.fileExists(atPath: session.appendingPathComponent("checkpoint.tmp-race").path) == false)
    }
}

private struct PersistenceSymlinkFixture {
    let parent: URL
    let base: URL
    let outside: URL
    let sessionIdentifier: String

    func remove() {
        try? FileManager.default.removeItem(at: parent)
    }
}

private func makeFixture(prefix: String) -> PersistenceSymlinkFixture {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
        "inno-persistence-\(prefix)-\(UUID().uuidString)",
        isDirectory: true
    )
    return PersistenceSymlinkFixture(
        parent: parent,
        base: parent.appendingPathComponent("base", isDirectory: true),
        outside: parent.appendingPathComponent("outside", isDirectory: true),
        sessionIdentifier: "test.persistence.\(prefix).\(UUID().uuidString)"
    )
}

private func sessionDirectory(base: URL, sessionIdentifier: String) -> URL {
    base
        .appendingPathComponent("InnoNetworkDownload", isDirectory: true)
        .appendingPathComponent(
            DownloadSessionStorageKey.component(for: sessionIdentifier),
            isDirectory: true
        )
}

private final class ParentSwapRecorder: @unchecked Sendable {
    private struct State {
        var errorDescription: String?
    }

    private let movedSession: URL
    private let outside: URL
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(movedSession: URL, outside: URL) {
        self.movedSession = movedSession
        self.outside = outside
    }

    func perform(sessionURL: URL) {
        do {
            try FileManager.default.moveItem(at: sessionURL, to: movedSession)
            try FileManager.default.createSymbolicLink(
                at: sessionURL,
                withDestinationURL: outside
            )
        } catch {
            state.withLock { $0.errorDescription = String(describing: error) }
        }
    }

    var errorDescription: String? {
        state.withLock { $0.errorDescription }
    }
}

private final class TemporaryEntrySwapRecorder: @unchecked Sendable {
    private let target: URL
    private let state = OSAllocatedUnfairLock(initialState: false)

    init(target: URL) {
        self.target = target
    }

    func perform(directoryDescriptor: Int32, temporaryName: String) {
        let didUnlink =
            temporaryName.withCString {
                Darwin.unlinkat(directoryDescriptor, $0, 0)
            } == 0
        let didLink =
            target.path.withCString { targetPointer in
                temporaryName.withCString { namePointer in
                    Darwin.symlinkat(targetPointer, directoryDescriptor, namePointer)
                }
            } == 0
        state.withLock { $0 = didUnlink && didLink }
    }

    var didSwap: Bool {
        state.withLock { $0 }
    }
}
