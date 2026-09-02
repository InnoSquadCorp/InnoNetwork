import Darwin
import Foundation

actor HLSOfflinePackageCheckpointWriter {
    private let store: HLSOfflinePackageResumeStore

    init(store: HLSOfflinePackageResumeStore) {
        self.store = store
    }

    func record(
        index: Int,
        relativePath: String,
        fileURL: URL
    ) throws {
        let values = try fileURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize
        else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.synchronize()
        try handle.close()
        try Self.synchronizeDirectory(
            at: fileURL.deletingLastPathComponent()
        )
        let record = HLSOfflinePackageResumeStore.CompletedResource(
            index: index,
            path: relativePath,
            byteCount: Int64(fileSize),
            sha256: try HLSOfflinePackageIntegrity.sha256(of: fileURL)
        )
        try store.save(completedResource: record)
    }

    private static func synchronizeDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
