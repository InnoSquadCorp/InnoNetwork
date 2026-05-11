import Foundation
import InnoNetwork

/// Configuration for ``PersistentResponseCache``.
///
/// `directoryURL` is the only required parameter; the remaining knobs default
/// to the values documented in the 4.0.0 RFC (50 MB total, 1,000 entries,
/// 5 MB per entry, no authenticated responses, no `Cache-Control: private`
/// responses, no `Set-Cookie` responses, `.completeUnlessOpen` data protection).
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

    /// Directory the cache uses for its `index.json` and SHA-256-addressed
    /// body files. The directory is created on first use. The cache writes
    /// only to its own subtree (`index.json` and `bodies/`); other files
    /// inside the directory are never deleted.
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
    /// are eligible for storage. Defaults to `false` for privacy.
    public let storesAuthenticatedResponses: Bool
    /// When `true`, responses with `Set-Cookie` headers are eligible for
    /// storage. Defaults to `false` for privacy.
    public let storesSetCookieResponses: Bool
    /// Durability policy for the index file. Defaults to ``PersistenceFsyncPolicy/onCheckpoint``.
    public let persistenceFsyncPolicy: PersistenceFsyncPolicy
    /// File protection class applied after cache directory and file creation.
    ///
    /// Defaults to ``DataProtectionClass/completeUnlessOpen``. Non-iOS-family
    /// platforms treat this as a no-op even when Foundation exposes the
    /// constants.
    /// ``DataProtectionClass/none`` requests `NSFileProtectionNone` for
    /// cache-owned paths instead of skipping existing protection updates.
    public let dataProtectionClass: DataProtectionClass

    /// Build a configuration. Only `directoryURL` is required; defaults match
    /// the 4.0.0 RFC ("Implementation decisions" table).
    public init(
        directoryURL: URL,
        maxBytes: Int = 50 * 1024 * 1024,
        maxEntries: Int = 1_000,
        maxEntryBytes: Int = 5 * 1024 * 1024,
        storesAuthenticatedResponses: Bool = false,
        storesSetCookieResponses: Bool = false,
        persistenceFsyncPolicy: PersistenceFsyncPolicy = .onCheckpoint,
        dataProtectionClass: DataProtectionClass = .completeUnlessOpen
    ) {
        self.directoryURL = directoryURL
        self.maxBytes = max(1, maxBytes)
        self.maxEntries = max(1, maxEntries)
        self.maxEntryBytes = max(1, maxEntryBytes)
        self.storesAuthenticatedResponses = storesAuthenticatedResponses
        self.storesSetCookieResponses = storesSetCookieResponses
        self.persistenceFsyncPolicy = persistenceFsyncPolicy
        self.dataProtectionClass = dataProtectionClass
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
