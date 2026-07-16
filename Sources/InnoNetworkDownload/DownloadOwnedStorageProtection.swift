import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Applies the storage attributes shared by download-owned metadata, staging
/// directories, and staged payloads. Final delivery copies only payload bytes
/// into a caller-owned inode, so these library attributes never transfer to
/// the caller's destination.
enum DownloadOwnedStorageProtection {
    #if canImport(Darwin)
    private static let backupExclusionValue: Data? = try? PropertyListSerialization.data(
        fromPropertyList: "com.apple.backupd",
        format: .binary,
        options: 0
    )

    /// Applies attributes to the already-open inode. Persistence uses this
    /// overload so metadata hardening cannot be redirected by a path swap.
    static func apply(toFileDescriptor descriptor: Int32) {
        if let backupExclusionValue {
            backupExclusionValue.withUnsafeBytes { bytes in
                _ = "com.apple.metadata:com_apple_backup_excludeItem".withCString { name in
                    fsetxattr(
                        descriptor,
                        name,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        0
                    )
                }
            }
        }

        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        // Public Darwin fcntl command. Protection class C corresponds to
        // complete-until-first-user-authentication, matching the Foundation
        // attribute used by the URL-based helper below.
        let protectionClassC: Int32 = 3
        _ = fcntl(descriptor, F_SETPROTECTIONCLASS, protectionClassC)
        #endif
    }
    #endif

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
