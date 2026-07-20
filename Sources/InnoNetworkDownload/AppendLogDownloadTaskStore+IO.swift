import Darwin
import Foundation

extension AppendLogDownloadTaskStore {
    struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let type: mode_t

        init(_ information: stat) {
            device = information.st_dev
            inode = information.st_ino
            type = information.st_mode & S_IFMT
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device
                && lhs.inode == rhs.inode
                && lhs.type == rhs.type
        }
    }

    /// Package-only seams for failure and race tests. Production operations
    /// remain descriptor-relative; tests can fail a rename/unlink or swap the
    /// visible parent after the session descriptor has already been anchored.
    package struct FileOperations: Sendable {
        package var renameEntry: @Sendable (_ directoryDescriptor: Int32, _ oldName: String, _ newName: String) -> Int32
        package var unlinkEntry: @Sendable (_ directoryDescriptor: Int32, _ name: String) -> Int32
        package var temporaryName: @Sendable (_ destinationName: String) -> String
        package var quarantineName: @Sendable (_ sourceName: String) -> String
        package var willRenameTemporaryEntry: @Sendable (_ directoryDescriptor: Int32, _ temporaryName: String) -> Void
        package var didOpenSessionDirectory: @Sendable (_ canonicalSessionDirectoryURL: URL) -> Void

        package init(
            renameEntry:
                @escaping @Sendable (
                    _ directoryDescriptor: Int32,
                    _ oldName: String,
                    _ newName: String
                ) -> Int32 = { descriptor, oldName, newName in
                    oldName.withCString { oldPointer in
                        newName.withCString { newPointer in
                            Darwin.renameat(descriptor, oldPointer, descriptor, newPointer)
                        }
                    }
                },
            unlinkEntry:
                @escaping @Sendable (
                    _ directoryDescriptor: Int32,
                    _ name: String
                ) -> Int32 = { descriptor, name in
                    name.withCString { Darwin.unlinkat(descriptor, $0, 0) }
                },
            temporaryName: @escaping @Sendable (_ destinationName: String) -> String = { name in
                let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
                return "\(stem).tmp-\(UUID().uuidString)"
            },
            quarantineName: @escaping @Sendable (_ sourceName: String) -> String = { name in
                let url = URL(fileURLWithPath: name)
                let stem = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                let suffix = UUID().uuidString
                return ext.isEmpty
                    ? "\(stem).corrupted-\(suffix)"
                    : "\(stem).corrupted-\(suffix).\(ext)"
            },
            willRenameTemporaryEntry:
                @escaping @Sendable (
                    _ directoryDescriptor: Int32,
                    _ temporaryName: String
                ) -> Void = { _, _ in },
            didOpenSessionDirectory:
                @escaping @Sendable (
                    _ canonicalSessionDirectoryURL: URL
                ) -> Void = { _ in }
        ) {
            self.renameEntry = renameEntry
            self.unlinkEntry = unlinkEntry
            self.temporaryName = temporaryName
            self.quarantineName = quarantineName
            self.willRenameTemporaryEntry = willRenameTemporaryEntry
            self.didOpenSessionDirectory = didOpenSessionDirectory
        }

        static let live = Self()
    }

    struct AnchoredSessionDirectory: Sendable {
        let descriptor: Int32
    }

    static let checkpointName = "checkpoint.json"
    static let logName = "events.log"
    static let lockName = ".lock"

    static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == CocoaError.Code.fileNoSuchFile.rawValue
                || nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue
        }
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)
    }

    static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    static func defaultBaseDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Resolves only the caller-owned base path. Persistence-owned components
    /// are subsequently created/opened with `mkdirat`/`openat(O_NOFOLLOW)` so
    /// a shared container cannot redirect the root or session through a
    /// symbolic link. Resolving the base keeps compatibility with callers
    /// whose chosen App Group/container path itself contains ancestor links.
    static func openAnchoredSessionDirectory(
        baseDirectoryURL: URL,
        sessionStorageComponent: String,
        fileManager: FileManager,
        operations: FileOperations
    ) throws -> AnchoredSessionDirectory {
        try fileManager.createDirectory(
            at: baseDirectoryURL,
            withIntermediateDirectories: true
        )
        let canonicalBaseURL = baseDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let baseDescriptor = open(
            canonicalBaseURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard baseDescriptor >= 0 else { throw posixError() }
        defer { close(baseDescriptor) }
        try requireDirectory(descriptor: baseDescriptor)

        let rootName = "InnoNetworkDownload"
        let rootDescriptor = try openOrCreateDirectory(
            parentDescriptor: baseDescriptor,
            name: rootName
        )
        defer { close(rootDescriptor) }
        let canonicalRootURL = canonicalBaseURL.appendingPathComponent(rootName, isDirectory: true)
        DownloadOwnedStorageProtection.apply(toFileDescriptor: rootDescriptor)

        let sessionDescriptor = try openOrCreateDirectory(
            parentDescriptor: rootDescriptor,
            name: sessionStorageComponent
        )
        let canonicalSessionURL = canonicalRootURL.appendingPathComponent(
            sessionStorageComponent,
            isDirectory: true
        )
        DownloadOwnedStorageProtection.apply(toFileDescriptor: sessionDescriptor)
        operations.didOpenSessionDirectory(canonicalSessionURL)
        return AnchoredSessionDirectory(descriptor: sessionDescriptor)
    }

    static func openOrCreateDirectory(
        parentDescriptor: Int32,
        name: String
    ) throws -> Int32 {
        let mkdirResult = name.withCString {
            Darwin.mkdirat(parentDescriptor, $0, S_IRWXU)
        }
        if mkdirResult != 0, errno != EEXIST {
            throw posixError()
        }

        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else { throw posixError() }
        do {
            try requireDirectory(descriptor: descriptor)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func requireDirectory(descriptor: Int32) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw posixError() }
        guard information.st_mode & S_IFMT == S_IFDIR else { throw posixError(ENOTDIR) }
    }

    static func openRegularFile(
        directoryDescriptor: Int32,
        name: String,
        flags: Int32,
        mode: mode_t = S_IRUSR | S_IWUSR
    ) throws -> (descriptor: Int32, identity: FileIdentity) {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                flags | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                mode
            )
        }
        guard descriptor >= 0 else { throw posixError() }
        do {
            var information = stat()
            guard fstat(descriptor, &information) == 0 else { throw posixError() }
            guard information.st_mode & S_IFMT == S_IFREG else { throw posixError(EINVAL) }
            // Persistence owns every managed file and never creates hard
            // links. Reject a pre-existing multi-link inode so appending to a
            // tampered log cannot mutate bytes through a name outside the
            // anchored session directory.
            guard information.st_nlink == 1 else { throw posixError(EMLINK) }
            return (descriptor, FileIdentity(information))
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func openOrCreateRegularFile(
        directoryDescriptor: Int32,
        name: String,
        existingFlags: Int32,
        mode: mode_t = S_IRUSR | S_IWUSR
    ) throws -> (descriptor: Int32, identity: FileIdentity, created: Bool) {
        do {
            let opened = try openRegularFile(
                directoryDescriptor: directoryDescriptor,
                name: name,
                flags: existingFlags | O_CREAT | O_EXCL,
                mode: mode
            )
            return (opened.descriptor, opened.identity, true)
        } catch let error as POSIXError where error.code == .EEXIST {
            let opened = try openRegularFile(
                directoryDescriptor: directoryDescriptor,
                name: name,
                flags: existingFlags,
                mode: mode
            )
            return (opened.descriptor, opened.identity, false)
        }
    }

    static func entryIdentity(
        directoryDescriptor: Int32,
        name: String
    ) throws -> FileIdentity? {
        try entryInformation(
            directoryDescriptor: directoryDescriptor,
            name: name
        ).map(FileIdentity.init)
    }

    static func entryInformation(
        directoryDescriptor: Int32,
        name: String
    ) throws -> stat? {
        var information = stat()
        let result = name.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return information }
        if errno == ENOENT { return nil }
        throw posixError()
    }

    static func readData(
        directoryDescriptor: Int32,
        name: String,
        reader: @Sendable (Int32) throws -> Data
    ) throws -> (data: Data, identity: FileIdentity)? {
        let opened: (descriptor: Int32, identity: FileIdentity)
        do {
            opened = try openRegularFile(
                directoryDescriptor: directoryDescriptor,
                name: name,
                flags: O_RDONLY
            )
        } catch  where isMissingFileError(error) {
            return nil
        }
        defer { close(opened.descriptor) }
        return (try reader(opened.descriptor), opened.identity)
    }

    static func readAll(from descriptor: Int32) throws -> Data {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw posixError() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw posixError(EIO) }
                offset += count
            }
        }
    }

    static func writeAtomically(
        data: Data,
        destinationName: String,
        directoryDescriptor: Int32,
        operations: FileOperations,
        fsyncBeforeRename: Bool = false,
        fsync: @escaping @Sendable (Int32) -> Int32 = Darwin.fsync
    ) throws {
        let temporaryName = operations.temporaryName(destinationName)
        let opened = try openRegularFile(
            directoryDescriptor: directoryDescriptor,
            name: temporaryName,
            flags: O_WRONLY | O_CREAT | O_EXCL
        )
        var shouldCleanupTemporaryEntry = true
        defer {
            close(opened.descriptor)
            if shouldCleanupTemporaryEntry {
                _ = operations.unlinkEntry(directoryDescriptor, temporaryName)
            }
        }

        // Apply protection before writing any payload bytes. A crash during
        // the write may leave the temporary inode behind, and resume metadata
        // must never spend that interval with weaker attributes.
        DownloadOwnedStorageProtection.apply(toFileDescriptor: opened.descriptor)
        try writeAll(data, to: opened.descriptor)
        if fsyncBeforeRename {
            try fsyncFileDescriptor(opened.descriptor, fsync: fsync)
        }

        operations.willRenameTemporaryEntry(directoryDescriptor, temporaryName)
        guard
            try entryIdentity(
                directoryDescriptor: directoryDescriptor,
                name: temporaryName
            ) == opened.identity
        else {
            throw posixError(EBUSY)
        }
        guard operations.renameEntry(directoryDescriptor, temporaryName, destinationName) == 0 else {
            throw posixError()
        }
        shouldCleanupTemporaryEntry = false

        guard
            try entryIdentity(
                directoryDescriptor: directoryDescriptor,
                name: destinationName
            ) == opened.identity
        else {
            // The visible entry no longer names the inode we installed. Do
            // not unlink an identity we cannot prove belongs to this write.
            throw posixError(EBUSY)
        }
        if fsyncBeforeRename {
            try fsyncFileDescriptor(directoryDescriptor, fsync: fsync)
        }
    }

    /// Kept for direct low-level tests. Store-authoritative writes use the
    /// descriptor-relative overload above.
    static func writeAtomically(
        data: Data,
        to fileURL: URL,
        fileManager _: FileManager,
        fsyncBeforeRename: Bool = false,
        fsync: @escaping @Sendable (Int32) -> Int32 = Darwin.fsync
    ) throws {
        let parentURL = fileURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let descriptor = open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        try writeAtomically(
            data: data,
            destinationName: fileURL.lastPathComponent,
            directoryDescriptor: descriptor,
            operations: .live,
            fsyncBeforeRename: fsyncBeforeRename,
            fsync: fsync
        )
    }

    static func resetLog(
        directoryDescriptor: Int32,
        operations: FileOperations
    ) throws {
        try writeAtomically(
            data: Data(),
            destinationName: logName,
            directoryDescriptor: directoryDescriptor,
            operations: operations
        )
    }

    static func fsyncFileDescriptor(
        _ fileDescriptor: Int32,
        fsync: @Sendable (Int32) -> Int32
    ) throws {
        guard fsync(fileDescriptor) == 0 else { throw posixError() }
    }

    static func fileSize(
        directoryDescriptor: Int32,
        name: String
    ) throws -> UInt64 {
        guard
            let information = try entryInformation(
                directoryDescriptor: directoryDescriptor,
                name: name
            )
        else { return 0 }
        let type = information.st_mode & S_IFMT
        guard type == S_IFREG else {
            throw posixError(type == S_IFLNK ? ELOOP : EINVAL)
        }
        return UInt64(max(0, information.st_size))
    }

    static func openLockDescriptor(
        directoryDescriptor: Int32
    ) throws -> Int32 {
        let opened = try openOrCreateRegularFile(
            directoryDescriptor: directoryDescriptor,
            name: lockName,
            existingFlags: O_RDWR
        )
        if opened.created {
            DownloadOwnedStorageProtection.apply(toFileDescriptor: opened.descriptor)
        }
        return opened.descriptor
    }

    static func acquireDirectoryLockBlocking(
        directoryDescriptor: Int32,
        timeout: TimeInterval
    ) throws -> Int32 {
        let descriptor = try openLockDescriptor(directoryDescriptor: directoryDescriptor)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockErrno = errno
            if lockErrno == EINTR { continue }
            if lockErrno != EWOULDBLOCK && lockErrno != EAGAIN || clock.now >= deadline {
                close(descriptor)
                throw CocoaError(.fileLocking)
            }
            usleep(50_000)
        }
        return descriptor
    }

    static func awaitDirectoryLock(
        descriptor: Int32,
        timeout: TimeInterval
    ) async throws -> Int32 {
        guard flock(descriptor, LOCK_EX | LOCK_NB) != 0 else {
            return descriptor
        }
        return try await awaitContendedDirectoryLock(
            descriptor: descriptor,
            timeout: timeout,
            initialErrno: errno
        )
    }

    private static func awaitContendedDirectoryLock(
        descriptor: Int32,
        timeout: TimeInterval,
        initialErrno: Int32
    ) async throws -> Int32 {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeout)
        var backoffMilliseconds = 1
        var lockErrno = initialErrno
        while true {
            if lockErrno != EINTR {
                if lockErrno != EWOULDBLOCK && lockErrno != EAGAIN || clock.now >= deadline {
                    close(descriptor)
                    throw CocoaError(.fileLocking)
                }
                do {
                    try await Task.sleep(for: .milliseconds(backoffMilliseconds))
                } catch {
                    close(descriptor)
                    throw error
                }
                backoffMilliseconds = min(backoffMilliseconds * 2, 50)
            }

            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return descriptor
            }
            lockErrno = errno
        }
    }

    static func releaseDirectoryLock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

}
