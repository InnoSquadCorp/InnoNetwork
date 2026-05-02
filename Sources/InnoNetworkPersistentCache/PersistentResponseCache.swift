import CryptoKit
import Foundation
import InnoNetwork

/// Configuration for ``PersistentResponseCache``.
///
/// `directoryURL` is the only required parameter; the remaining knobs default
/// to the values documented in the 4.0.0 RFC (50 MB total, 1,000 entries,
/// 5 MB per entry, no authenticated responses, no `Set-Cookie` responses).
public struct PersistentResponseCacheConfiguration: Sendable, Equatable {
    /// Durability policy for the on-disk index file.
    ///
    /// `fsync(_:)` forces an in-flight write through the OS page cache to
    /// stable storage. `.always` opens an fd on the renamed index after the
    /// atomic write and `fsync`s it (plus the parent directory) so the index
    /// survives a hard crash. `.onCheckpoint`/`.never` retain the historic
    /// `data.write(to:options:.atomic)` semantics where the rename is
    /// linearized but the bytes are not necessarily flushed to platter.
    public enum PersistenceFsyncPolicy: Sendable, Equatable {
        /// `fsync(_:)` the index file and parent directory after every write.
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
    /// When `true`, responses to requests carrying an `Authorization` header
    /// are eligible for storage. Defaults to `false` for privacy.
    public let storesAuthenticatedResponses: Bool
    /// When `true`, responses with `Set-Cookie` headers are eligible for
    /// storage. Defaults to `false` for privacy.
    public let storesSetCookieResponses: Bool
    /// Durability policy for the index file. Defaults to ``PersistenceFsyncPolicy/onCheckpoint``.
    public let persistenceFsyncPolicy: PersistenceFsyncPolicy

    /// Build a configuration. Only `directoryURL` is required; defaults match
    /// the 4.0.0 RFC ("Implementation decisions" table).
    public init(
        directoryURL: URL,
        maxBytes: Int = 50 * 1024 * 1024,
        maxEntries: Int = 1_000,
        maxEntryBytes: Int = 5 * 1024 * 1024,
        storesAuthenticatedResponses: Bool = false,
        storesSetCookieResponses: Bool = false,
        persistenceFsyncPolicy: PersistenceFsyncPolicy = .onCheckpoint
    ) {
        self.directoryURL = directoryURL
        self.maxBytes = max(1, maxBytes)
        self.maxEntries = max(1, maxEntries)
        self.maxEntryBytes = max(1, maxEntryBytes)
        self.storesAuthenticatedResponses = storesAuthenticatedResponses
        self.storesSetCookieResponses = storesSetCookieResponses
        self.persistenceFsyncPolicy = persistenceFsyncPolicy
    }
}

/// Persistent on-disk implementation of ``ResponseCache``.
///
/// Stores response bodies in a flat directory keyed by SHA-256 hashes of the
/// canonical `(method, url, vary)` tuple. Survives process restarts and app
/// upgrades; corrupt or unknown-version indexes are recovered by deleting the
/// cache's own subtree (never the user-supplied directory root).
///
/// The cache enforces a synchronous LRU bound on every write so the disk
/// footprint stays within the configured byte and entry budgets.
public actor PersistentResponseCache: ResponseCache {
    private static let formatVersion = 1

    private struct DiskKey: Codable, Hashable, Sendable {
        let method: String
        let url: String
        let headers: [String]

        init(_ key: ResponseCacheKey) {
            self.method = key.method
            self.url = key.url
            self.headers = key.headers
        }
    }

    private struct Index: Codable, Sendable {
        var version: Int
        var entries: [String: Entry]
    }

    private struct Entry: Codable, Sendable {
        let key: DiskKey
        let statusCode: Int
        let headers: [String: String]
        let storedAt: Date
        let requiresRevalidation: Bool
        let varyHeaders: [String: String?]?
        let bodyFileName: String
        let byteCost: Int
        var lastAccessedAt: Date
    }

    private let configuration: PersistentResponseCacheConfiguration
    private let fileManager: FileManager
    private let bodiesDirectoryURL: URL
    private let indexURL: URL
    private var index: Index

    /// Open or create a persistent response cache at `configuration.directoryURL`.
    ///
    /// Throws if the directory cannot be created. Unknown index versions and
    /// decode failures are not surfaced as errors — the cache resets its own
    /// state and continues, so a corrupt cache from a prior version is safe to
    /// inherit.
    public init(
        configuration: PersistentResponseCacheConfiguration,
        fileManager: FileManager = .default
    ) throws {
        self.configuration = configuration
        self.fileManager = fileManager
        self.bodiesDirectoryURL = configuration.directoryURL.appendingPathComponent("bodies", isDirectory: true)
        self.indexURL = configuration.directoryURL.appendingPathComponent("index.json", isDirectory: false)

        try fileManager.createDirectory(at: bodiesDirectoryURL, withIntermediateDirectories: true)
        self.index = try Self.loadIndex(
            from: indexURL,
            directoryURL: configuration.directoryURL,
            fileManager: fileManager
        )
    }

    /// Look up a cached response for `key`. Returns `nil` on miss or when the
    /// body file cannot be read (the index entry is dropped). The recorded
    /// `lastAccessedAt` is best-effort persisted; a failure to write the
    /// index never demotes a successful read to a miss.
    public func get(_ key: ResponseCacheKey) async -> CachedResponse? {
        let diskKey = DiskKey(key)
        let id = Self.identifier(for: diskKey)
        guard var entry = index.entries[id] else { return nil }
        let bodyURL = bodiesDirectoryURL.appendingPathComponent(entry.bodyFileName, isDirectory: false)

        let data: Data
        do {
            data = try Data(contentsOf: bodyURL)
        } catch {
            removeEntry(id: id, entry: entry)
            try? persistIndex()
            return nil
        }

        entry.lastAccessedAt = Date()
        index.entries[id] = entry
        try? persistIndex()

        return CachedResponse(
            data: data,
            statusCode: entry.statusCode,
            headers: entry.headers,
            storedAt: entry.storedAt,
            requiresRevalidation: entry.requiresRevalidation,
            varyHeaders: entry.varyHeaders
        )
    }

    /// Store `value` under `key`. Drops the entry instead of storing it when
    /// the privacy policy rejects it (authenticated request or `Set-Cookie`
    /// response with the corresponding flags off) or when the body exceeds
    /// ``PersistentResponseCacheConfiguration/maxEntryBytes``. Eviction runs
    /// synchronously to keep the on-disk footprint within budget.
    public func set(_ key: ResponseCacheKey, _ value: CachedResponse) async {
        guard shouldStore(key: key, response: value), value.data.count <= configuration.maxEntryBytes else {
            await invalidate(key)
            return
        }

        let diskKey = DiskKey(key)
        let id = Self.identifier(for: diskKey)
        let bodyFileName = "\(id).body"
        let bodyURL = bodiesDirectoryURL.appendingPathComponent(bodyFileName, isDirectory: false)
        let byteCost =
            value.data.count
            + value.headers.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        let entry = Entry(
            key: diskKey,
            statusCode: value.statusCode,
            headers: value.headers,
            storedAt: value.storedAt,
            requiresRevalidation: value.requiresRevalidation,
            varyHeaders: value.varyHeaders,
            bodyFileName: bodyFileName,
            byteCost: byteCost,
            lastAccessedAt: Date()
        )

        do {
            try value.data.write(to: bodyURL, options: .atomic)
            if let old = index.entries[id], old.bodyFileName != bodyFileName {
                removeBody(fileName: old.bodyFileName)
            }
            index.entries[id] = entry
            evictIfNeeded()
            try persistIndex()
        } catch {
            removeBody(fileName: bodyFileName)
        }
    }

    /// Remove the entry for `key` from the index and delete its body file.
    public func invalidate(_ key: ResponseCacheKey) async {
        let id = Self.identifier(for: DiskKey(key))
        if let entry = index.entries.removeValue(forKey: id) {
            removeBody(fileName: entry.bodyFileName)
            try? persistIndex()
        }
    }

    /// Clear all entries. Resets the index and recreates the bodies directory.
    /// The user-supplied configuration directory itself is left in place.
    public func removeAll() async {
        index.entries.removeAll()
        try? fileManager.removeItem(at: bodiesDirectoryURL)
        try? fileManager.createDirectory(at: bodiesDirectoryURL, withIntermediateDirectories: true)
        try? persistIndex()
    }

    private func shouldStore(key: ResponseCacheKey, response: CachedResponse) -> Bool {
        if !configuration.storesAuthenticatedResponses,
            key.headers.contains(where: { $0.lowercased().hasPrefix("authorization:") })
        {
            return false
        }

        if !configuration.storesSetCookieResponses,
            response.headers.keys.contains(where: { $0.caseInsensitiveCompare("Set-Cookie") == .orderedSame })
        {
            return false
        }

        return true
    }

    private func evictIfNeeded() {
        while index.entries.count > configuration.maxEntries || totalBytes > configuration.maxBytes {
            guard let victim = index.entries.min(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt }) else {
                return
            }
            removeEntry(id: victim.key, entry: victim.value)
        }
    }

    private var totalBytes: Int {
        index.entries.values.reduce(0) { $0 + $1.byteCost }
    }

    private func removeEntry(id: String, entry: Entry) {
        index.entries.removeValue(forKey: id)
        removeBody(fileName: entry.bodyFileName)
    }

    private func removeBody(fileName: String) {
        let bodyURL = bodiesDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
        try? fileManager.removeItem(at: bodyURL)
    }

    private func persistIndex() throws {
        let data = try JSONEncoder.persistentCache.encode(index)
        try data.write(to: indexURL, options: .atomic)
        guard configuration.persistenceFsyncPolicy == .always else { return }
        Self.fsyncFile(at: indexURL)
        Self.fsyncDirectory(at: configuration.directoryURL)
    }

    private static func fsyncFile(at url: URL) {
        let fd = url.withUnsafeFileSystemRepresentation { rep -> Int32 in
            guard let rep else { return -1 }
            return open(rep, O_RDONLY)
        }
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }

    private static func fsyncDirectory(at url: URL) {
        let fd = url.withUnsafeFileSystemRepresentation { rep -> Int32 in
            guard let rep else { return -1 }
            return open(rep, O_RDONLY)
        }
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }

    private static func loadIndex(
        from indexURL: URL,
        directoryURL: URL,
        fileManager: FileManager
    ) throws -> Index {
        guard fileManager.fileExists(atPath: indexURL.path) else {
            return Index(version: formatVersion, entries: [:])
        }

        let bodiesDirectoryURL = directoryURL.appendingPathComponent("bodies", isDirectory: true)

        do {
            let index = try JSONDecoder.persistentCache.decode(Index.self, from: Data(contentsOf: indexURL))
            guard index.version == formatVersion else {
                try resetCacheStorage(
                    indexURL: indexURL,
                    bodiesDirectoryURL: bodiesDirectoryURL,
                    fileManager: fileManager
                )
                return Index(version: formatVersion, entries: [:])
            }
            return index
        } catch {
            try resetCacheStorage(
                indexURL: indexURL,
                bodiesDirectoryURL: bodiesDirectoryURL,
                fileManager: fileManager
            )
            return Index(version: formatVersion, entries: [:])
        }
    }

    private static func resetCacheStorage(
        indexURL: URL,
        bodiesDirectoryURL: URL,
        fileManager: FileManager
    ) throws {
        try? fileManager.removeItem(at: indexURL)
        try? fileManager.removeItem(at: bodiesDirectoryURL)
        try fileManager.createDirectory(at: bodiesDirectoryURL, withIntermediateDirectories: true)
    }

    private static func identifier(for key: DiskKey) -> String {
        let data = try? JSONEncoder.persistentCache.encode(key)
        let digest = SHA256.hash(data: data ?? Data())
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var persistentCache: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var persistentCache: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
