import Foundation
import InnoNetwork

/// Configuration for ``PersistentResponseCache``.
///
/// `directoryURL` is the only required parameter; the remaining knobs use the
/// current hardened defaults (50 MB total, 1,000 entries,
/// 5 MB per entry, no authenticated responses, no `Cache-Control: private`
/// responses, no `Set-Cookie` responses,
/// `.completeUntilFirstUserAuthentication` data protection).
public struct PersistentResponseCacheConfiguration: Sendable, Equatable {
    /// File protection class applied to the cache directory, index, and body files.
    public enum DataProtectionClass: Sendable, Equatable {
        /// File content is accessible only while the device is unlocked.
        case complete
        /// File content stays accessible while an already-open descriptor remains open.
        case completeUnlessOpen
        /// File content is accessible after the first device unlock.
        case completeUntilFirstUserAuthentication
        /// Request unprotected storage for cache-owned files.
        case none
    }

    /// Storage backend for the per-cache HMAC key that blinds sensitive
    /// request-header values in cache keys.
    ///
    /// `.file` (default) keeps the historic behavior: a 32-byte random key
    /// is generated on first use and persisted alongside the cache index,
    /// with the configured ``DataProtectionClass`` applied to the key file.
    ///
    /// `.keychain` stores the same 32-byte key as a generic-password
    /// Keychain item, allowing the key to outlive cache-directory wipes and
    /// to inherit a stronger accessibility class than file protection alone
    /// can provide. Only available on Darwin platforms; non-Darwin
    /// configurations fall back to `.file` at initialization time.
    public enum KeyStorage: Sendable, Equatable {
        /// Persist the HMAC key inside the cache directory as
        /// `cache-key-hmac.key`, protected by the configuration's
        /// ``DataProtectionClass``.
        case file
        /// Persist the HMAC key in the Keychain as a generic password.
        ///
        /// - Parameters:
        ///   - service: `kSecAttrService` value used to scope the item.
        ///     Combined with the cache directory path so multiple caches
        ///     in the same process do not collide.
        ///   - accessGroup: Optional `kSecAttrAccessGroup` for sharing the
        ///     key across an App Group / Keychain access group. Pass `nil`
        ///     to keep the key private to the current application.
        case keychain(service: String, accessGroup: String? = nil)
    }

    /// Durability policy for the on-disk index file.
    ///
    /// `.always` opens an fd on the renamed index after the atomic write and,
    /// on Darwin, first asks the filesystem for `F_FULLFSYNC` durability
    /// before falling back to `fsync(_:)` only when unsupported. It also
    /// flushes the parent directory so the renamed index survives a hard
    /// crash. `.onCheckpoint`/`.never` retain the historic
    /// `data.write(to:options:.atomic)` semantics where the rename is
    /// linearized but the bytes are not necessarily flushed to stable storage.
    public enum PersistenceFsyncPolicy: Sendable, Equatable {
        /// Fully synchronize the index file and parent directory after every write.
        case always
        /// Same as ``never`` for the persistent response cache: the cache
        /// rewrites the entire index on every change, so there is no
        /// distinct checkpoint boundary. Provided for API parity with
        /// ``DownloadConfiguration/PersistenceFsyncPolicy``.
        case onCheckpoint
        /// Rely on the OS to flush dirty pages on its own cadence.
        case never
    }

    /// Directory the cache uses for `index.json`, SHA-256-addressed body
    /// files, and the file-backed HMAC key when ``KeyStorage/file`` is used.
    /// The directory is created on first use. Cache-owned artifacts are
    /// excluded from backup, but the supplied root is not because it may also
    /// contain app-owned files. Unrelated files inside the directory are never
    /// deleted.
    public let directoryURL: URL
    /// Total byte budget across all body files. Eviction fires synchronously
    /// when this is exceeded.
    public let maxBytes: Int
    /// Maximum number of entries kept on disk. Eviction fires synchronously
    /// when this is exceeded.
    public let maxEntries: Int
    /// Per-entry hard cap. Responses larger than this are not stored.
    public let maxEntryBytes: Int
    /// When `true`, responses to requests carrying credential-like key headers
    /// are eligible for storage. Defaults to `false` for privacy. Responses to
    /// requests carrying `Authorization` still require an RFC 9111 §3.5
    /// permission directive (`public`, `must-revalidate`, or `s-maxage`).
    public let storesAuthenticatedResponses: Bool
    /// When `true`, responses with `Set-Cookie` headers are eligible for
    /// storage. Defaults to `false` for privacy.
    public let storesSetCookieResponses: Bool
    /// Durability policy for the index file. Defaults to ``PersistenceFsyncPolicy/onCheckpoint``.
    public let persistenceFsyncPolicy: PersistenceFsyncPolicy
    /// File protection class applied after cache directory and file creation.
    ///
    /// Defaults to ``DataProtectionClass/completeUntilFirstUserAuthentication``.
    /// This keeps background cache reads available after the first unlock while
    /// still protecting cache contents across device restarts. Non-iOS-family
    /// platforms treat this as a no-op even when Foundation exposes the
    /// constants.
    /// ``DataProtectionClass/none`` requests `NSFileProtectionNone` for
    /// cache-owned paths instead of skipping existing protection updates.
    public let dataProtectionClass: DataProtectionClass
    /// Storage backend for the HMAC key that blinds sensitive headers in
    /// the cache key. Defaults to ``KeyStorage/file``.
    public let keyStorage: KeyStorage

    /// Build a configuration. Only `directoryURL` is required; the remaining
    /// arguments use the current hardened defaults.
    public init(
        directoryURL: URL,
        maxBytes: Int = 50 * 1024 * 1024,
        maxEntries: Int = 1_000,
        maxEntryBytes: Int = 5 * 1024 * 1024,
        storesAuthenticatedResponses: Bool = false,
        storesSetCookieResponses: Bool = false,
        persistenceFsyncPolicy: PersistenceFsyncPolicy = .onCheckpoint,
        dataProtectionClass: DataProtectionClass = .completeUntilFirstUserAuthentication,
        keyStorage: KeyStorage = .file
    ) {
        self.directoryURL = directoryURL
        self.maxBytes = max(1, maxBytes)
        self.maxEntries = max(1, maxEntries)
        self.maxEntryBytes = max(1, maxEntryBytes)
        self.storesAuthenticatedResponses = storesAuthenticatedResponses
        self.storesSetCookieResponses = storesSetCookieResponses
        self.persistenceFsyncPolicy = persistenceFsyncPolicy
        self.dataProtectionClass = dataProtectionClass
        self.keyStorage = keyStorage
    }

    /// Standard subdirectory for storing persistent cache files in an App Group container.
    ///
    /// App Group containers are only available on Apple platforms (Darwin).
    /// Calling this on other platforms throws
    /// ``NetworkError/configuration(reason:)`` with `.invalidRequest`.
    public static func appGroupDirectoryURL(
        groupIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        #if canImport(Darwin)
        guard
            let container = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: groupIdentifier
            )
        else {
            throw NetworkError.configuration(
                reason: .invalidRequest(
                    "App Group container '\(groupIdentifier)' is unavailable."
                ))
        }
        return container.appendingPathComponent("InnoNetworkPersistentCache", isDirectory: true)
        #else
        throw NetworkError.configuration(
            reason: .invalidRequest(
                "App Group containers are not available on this platform."
            ))
        #endif
    }
}
