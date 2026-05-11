import Darwin
import Foundation

// Split out of `DownloadTaskPersistence.swift` so the low-level disk I/O —
// directory layout, atomic writes, fsync, file-size lookup, and the
// inter-process flock dance — lives in one place. All helpers stay
// `static` and side-effect-free at the type level; this file only relocates
// code, no behaviour changes.
extension AppendLogDownloadTaskStore {

    static func defaultBaseDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static func ensureDirectoryExists(at directoryURL: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    static func writeAtomically(
        data: Data,
        to fileURL: URL,
        fileManager: FileManager,
        fsyncBeforeRename: Bool = false,
        fsync: @escaping @Sendable (Int32) -> Int32 = Darwin.fsync
    ) throws {
        let tempURL =
            fileURL
            .deletingPathExtension()
            .appendingPathExtension("tmp-\(UUID().uuidString)")

        try data.write(to: tempURL, options: .atomic)

        // For checkpoint writes (.always or .onCheckpoint), fsync the temp
        // file before the atomic rename so the rename observes a fully
        // committed payload. The empty resetLog path skips the fsync — the
        // log truncation does not need durability beyond what the rename
        // provides.
        if fsyncBeforeRename {
            let handle = try FileHandle(forReadingFrom: tempURL)
            defer { try? handle.close() }
            try fsyncFileDescriptor(handle.fileDescriptor, fsync: fsync)
        }

        if fileManager.fileExists(atPath: fileURL.path()) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: fileURL)
        }

        if fsyncBeforeRename {
            try fsyncParentDirectory(of: fileURL, fsync: fsync)
        }
    }

    static func resetLog(at logURL: URL, fileManager: FileManager) throws {
        let emptyData = Data()
        try writeAtomically(data: emptyData, to: logURL, fileManager: fileManager)
    }

    static func fsyncFileDescriptor(
        _ fileDescriptor: Int32,
        fsync: @Sendable (Int32) -> Int32
    ) throws {
        guard fsync(fileDescriptor) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
    }

    static func fsyncParentDirectory(
        of fileURL: URL,
        fsync: @Sendable (Int32) -> Int32
    ) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        let descriptor = open(directoryURL.path, O_RDONLY)
        guard descriptor >= 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
        defer { close(descriptor) }
        try fsyncFileDescriptor(descriptor, fsync: fsync)
    }

    static func fileSize(at url: URL, fileManager: FileManager) -> UInt64 {
        guard
            fileManager.fileExists(atPath: url.path()),
            let attributes = try? fileManager.attributesOfItem(atPath: url.path()),
            let fileSize = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return fileSize.uint64Value
    }

    static func withDirectoryLock<T>(
        lockURL: URL,
        fileManager: FileManager,
        timeout: TimeInterval = 10,
        _ work: () throws -> T
    ) throws -> T {
        let descriptor = try acquireDirectoryLockBlocking(
            lockURL: lockURL,
            fileManager: fileManager,
            timeout: timeout
        )
        defer { releaseDirectoryLock(descriptor) }
        return try work()
    }

    static func openLockDescriptor(
        lockURL: URL,
        fileManager: FileManager
    ) throws -> Int32 {
        try ensureDirectoryExists(at: lockURL.deletingLastPathComponent(), fileManager: fileManager)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        return descriptor
    }

    static func acquireDirectoryLockBlocking(
        lockURL: URL,
        fileManager: FileManager,
        timeout: TimeInterval
    ) throws -> Int32 {
        let descriptor = try openLockDescriptor(lockURL: lockURL, fileManager: fileManager)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockErrno = errno
            if lockErrno != EWOULDBLOCK && lockErrno != EAGAIN {
                close(descriptor)
                throw CocoaError(.fileLocking)
            }
            if clock.now >= deadline {
                close(descriptor)
                throw CocoaError(.fileLocking)
            }
            usleep(50_000)
        }
        return descriptor
    }

    /// Polls a previously-opened lock file descriptor with cooperative
    /// `Task.sleep` between attempts. The descriptor is opened ahead of time
    /// by the caller so this method does not need to capture the actor's
    /// non-Sendable `FileManager`.
    static func awaitDirectoryLock(
        descriptor: Int32,
        timeout: TimeInterval
    ) async throws -> Int32 {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockErrno = errno
            if lockErrno != EWOULDBLOCK && lockErrno != EAGAIN {
                close(descriptor)
                throw CocoaError(.fileLocking)
            }
            if clock.now >= deadline {
                close(descriptor)
                throw CocoaError(.fileLocking)
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                close(descriptor)
                throw error
            }
        }
        return descriptor
    }

    static func releaseDirectoryLock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
