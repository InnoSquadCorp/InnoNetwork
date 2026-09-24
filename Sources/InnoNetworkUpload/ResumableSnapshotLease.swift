import Darwin
import Foundation

/// A private snapshot is live while its descriptor carries an exclusive lock.
/// The directory lock serializes creation with orphan discovery across processes.
final class ResumableSnapshotLease: Sendable {
    let url: URL
    let handle: FileHandle
    private let directoryDescriptor: Int32
    private let name: String

    init(parent: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let parentDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else { throw ResumableUploadError.unreadableFile }
        defer { close(parentDescriptor) }
        let directoryName = "innonetwork-resumable-v1"
        guard mkdirat(parentDescriptor, directoryName, 0o700) == 0 || errno == EEXIST else {
            throw ResumableUploadError.unreadableFile
        }
        let directory = openat(parentDescriptor, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ResumableUploadError.unreadableFile }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0,
            directoryInfo.st_uid == geteuid(), directoryInfo.st_mode & 0o777 == 0o700,
            flock(directory, LOCK_EX) == 0
        else {
            close(directory)
            throw ResumableUploadError.unreadableFile
        }
        var leased = false
        defer {
            flock(directory, LOCK_UN)
            if !leased { close(directory) }
        }
        let root = parent.appendingPathComponent(directoryName, isDirectory: true)
        Self.reapOrphans(in: root, descriptor: directory)
        let name = "\(UUID().uuidString).snapshot"
        let descriptor = openat(directory, name, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw ResumableUploadError.unreadableFile
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            unlinkat(directory, name, 0)
            throw ResumableUploadError.unreadableFile
        }
        self.directoryDescriptor = directory
        self.name = name
        self.url = root.appendingPathComponent(name)
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        leased = true
    }

    deinit {
        // Unlink while still holding the lease. A cleanup pass can never
        // mistake a live reader for an orphan during this transition.
        unlinkat(directoryDescriptor, name, 0)
        try? handle.close()
        close(directoryDescriptor)
    }

    private static func reapOrphans(in root: URL, descriptor directory: Int32) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names {
            guard name.hasSuffix(".snapshot"), UUID(uuidString: String(name.dropLast(9))) != nil else { continue }
            let descriptor = openat(directory, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600,
                flock(descriptor, LOCK_EX | LOCK_NB) == 0
            else { continue }
            var current = stat()
            if fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                current.st_ino == info.st_ino, current.st_dev == info.st_dev
            {
                unlinkat(directory, name, 0)
            }
        }
    }
}
