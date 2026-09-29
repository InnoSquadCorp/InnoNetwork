import Darwin
import Foundation
import os

/// Nonblocking, per-ID ownership across engines and processes. All participants
/// coordinate lock-file open/unlink with the directory lock, avoiding an inode
/// split when a completed upload removes its lock file. Directory locks cover
/// only these short filesystem operations, never async/network work.
final class ResumableUploadFileLease: Sendable {
    private struct Descriptors: Sendable {
        let directory: Int32
        let file: Int32
        let name: String
    }
    private let state: OSAllocatedUnfairLock<Descriptors?>

    init(directory url: URL, name: String) throws {
        let directory = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw CocoaError(.fileReadUnknown) }
        var acquired = false
        defer { if !acquired { close(directory) } }
        guard flock(directory, LOCK_EX) == 0 else { throw CocoaError(.fileLocking) }
        defer { flock(directory, LOCK_UN) }
        let descriptor = openat(directory, name, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { if !acquired { close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600
        else { throw CocoaError(.fileReadNoPermission) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw ResumableUploadError.uploadAlreadyInProgress }
            throw CocoaError(.fileLocking)
        }
        state = OSAllocatedUnfairLock(initialState: Descriptors(directory: directory, file: descriptor, name: name))
        acquired = true
    }

    func release() {
        state.withLock { descriptors in
            guard let owned = descriptors else { return }
            descriptors = nil
            // If cleanup cannot take the directory lock, leave the inert file
            // for the next owner rather than unlink without synchronization.
            if flock(owned.directory, LOCK_EX) == 0 {
                var held = stat()
                var current = stat()
                if fstat(owned.file, &held) == 0,
                    fstatat(owned.directory, owned.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                    held.st_dev == current.st_dev, held.st_ino == current.st_ino
                {
                    unlinkat(owned.directory, owned.name, 0)
                }
                close(owned.file)
                flock(owned.directory, LOCK_UN)
            } else {
                close(owned.file)
            }
            close(owned.directory)
        }
    }

    deinit { release() }
}
