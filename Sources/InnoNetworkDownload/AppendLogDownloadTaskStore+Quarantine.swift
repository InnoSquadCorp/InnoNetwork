import Darwin
import Foundation
import OSLog

extension AppendLogDownloadTaskStore {
    static let quarantineLogger = Logger(
        subsystem: "innosquad.network.download",
        category: "Persistence"
    )

    /// Quarantines the inode that was decoded/replayed and verifies its
    /// identity again after the move. Cooperating owners serialize through
    /// the session lock; a hostile concurrent replacement fails closed after
    /// the move. Descriptor-relative operations ensure that such a race never
    /// follows a symlink target outside the anchored session directory.
    static func quarantineFileIfNeeded(
        _ name: String,
        expectedIdentity: FileIdentity,
        directoryDescriptor: Int32,
        operations: FileOperations
    ) throws {
        guard
            let currentIdentity = try entryIdentity(
                directoryDescriptor: directoryDescriptor,
                name: name
            )
        else { return }
        guard currentIdentity == expectedIdentity else {
            throw posixError(EBUSY)
        }

        let corruptedName = operations.quarantineName(name)
        if operations.renameEntry(directoryDescriptor, name, corruptedName) == 0 {
            guard
                try entryIdentity(
                    directoryDescriptor: directoryDescriptor,
                    name: corruptedName
                ) == expectedIdentity
            else {
                throw posixError(EBUSY)
            }
            let opened = try openRegularFile(
                directoryDescriptor: directoryDescriptor,
                name: corruptedName,
                flags: O_RDONLY
            )
            defer { close(opened.descriptor) }
            guard opened.identity == expectedIdentity else {
                throw posixError(EBUSY)
            }
            DownloadOwnedStorageProtection.apply(toFileDescriptor: opened.descriptor)
            return
        }

        let renameError = posixError()
        quarantineLogger.fault(
            "Failed to quarantine corrupt persistence entry \(name, privacy: .private(mask: .hash)): \(renameError.localizedDescription, privacy: .private(mask: .hash)). Preserving the entry."
        )
        // There is no portable compare-and-unlink primitive. Retain the
        // corrupt entry rather than risk deleting a replacement installed
        // between an identity check and `unlinkat`.
        throw renameError
    }
}
