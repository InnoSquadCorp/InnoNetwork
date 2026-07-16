import Foundation

/// Applies the storage attributes shared by download-owned metadata, staging
/// directories, and staged payloads. Final delivery copies only payload bytes
/// into a caller-owned inode, so these library attributes never transfer to
/// the caller's destination.
enum DownloadOwnedStorageProtection {
    static func apply(to url: URL, fileManager: FileManager = .default) {
        let resourceValues = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard resourceValues?.isSymbolicLink != true else { return }

        #if canImport(Darwin)
        var resourceURL = url
        var backupResourceValues = URLResourceValues()
        backupResourceValues.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(backupResourceValues)
        #endif

        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #else
        _ = fileManager
        #endif
    }
}
