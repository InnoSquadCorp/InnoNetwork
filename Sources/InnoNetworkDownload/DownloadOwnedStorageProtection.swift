import Foundation

/// Applies the storage attributes shared by download-owned metadata files and
/// staging directories. The staged payload inode is intentionally excluded:
/// it is later moved to the caller's final destination, whose metadata
/// InnoNetwork must not change.
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
