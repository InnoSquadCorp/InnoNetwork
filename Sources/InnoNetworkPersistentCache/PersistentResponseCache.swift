import CryptoKit
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
    /// Defaults to ``DataProtectionClass/completeUnlessOpen``. Platforms that do
    /// not support Foundation file-protection attributes treat this as a no-op.
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
    /// Number of read-path `lastAccessedAt` updates that have not yet been
    /// flushed to disk. Reads are buffered to amortize the JSON-encode +
    /// atomic-write cost across many hits; insertions/deletions still flush
    /// immediately so durability of the working set is unaffected.
    private var pendingReadFlushes: Int = 0
    /// Flush threshold: every `readFlushBatchSize` cache hits triggers one
    /// best-effort `persistIndex(durable: false)`. Tuned conservatively so a
    /// process crash loses at most this many access-time updates — LRU
    /// ordering is recoverable from `storedAt` if the cache restarts cold.
    private let readFlushBatchSize: Int = 32

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
        Self.applyDataProtection(
            configuration.dataProtectionClass,
            to: configuration.directoryURL,
            fileManager: fileManager
        )
        Self.applyDataProtection(configuration.dataProtectionClass, to: bodiesDirectoryURL, fileManager: fileManager)
        let loadedIndex = try Self.loadIndex(
            from: indexURL,
            directoryURL: configuration.directoryURL,
            dataProtectionClass: configuration.dataProtectionClass,
            fileManager: fileManager
        )
        Self.applyDataProtectionToExistingCacheFiles(
            dataProtectionClass: configuration.dataProtectionClass,
            indexURL: indexURL,
            bodiesDirectoryURL: bodiesDirectoryURL,
            fileManager: fileManager
        )
        let policyScrubbedIndex = try Self.scrubPolicyRejectedEntriesOnOpen(
            loadedIndex,
            configuration: configuration,
            indexURL: indexURL,
            bodiesDirectoryURL: bodiesDirectoryURL,
            fileManager: fileManager
        )
        self.index = try Self.enforceBudgetsOnOpen(
            policyScrubbedIndex,
            configuration: configuration,
            indexURL: indexURL,
            bodiesDirectoryURL: bodiesDirectoryURL,
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
        guard shouldStore(key: entry.key, responseHeaders: entry.headers) else {
            removeEntry(id: id, entry: entry)
            try? persistIndex()
            return nil
        }
        let bodyURL = bodiesDirectoryURL.appendingPathComponent(entry.bodyFileName, isDirectory: false)

        // Body reads (potentially up to `maxEntryBytes`, default 5 MB) run on
        // a detached task so the actor can process unrelated requests while
        // slow flash blocks the read. The actor remains the single writer of
        // `index`, so suspending here does not violate the cache invariants:
        // a concurrent set/invalidate for this key will queue and observe the
        // up-to-date state once we resume.
        let data: Data
        do {
            data = try await Self.readBodyData(at: bodyURL)
        } catch {
            removeEntry(id: id, entry: entry)
            try? persistIndex()
            return nil
        }
        guard data.count <= configuration.maxEntryBytes else {
            removeEntry(id: id, entry: entry)
            try? persistIndex()
            return nil
        }

        entry.lastAccessedAt = Date()
        index.entries[id] = entry
        // Read-path metadata updates skip the durability fsync AND are
        // batched: only every `readFlushBatchSize`-th hit triggers an
        // atomic-write. Reasons:
        //   * `.always` fsync exists to make insertions durable. LRU
        //     bookkeeping is recoverable best-effort.
        //   * JSON-encoding the full index + atomic rename on every cache
        //     hit dominates the hot read path on devices with slow flash.
        //   * A process crash loses at most `readFlushBatchSize` access-time
        //     updates; ordering can be reconstructed from `storedAt` and
        //     subsequent reads quickly re-establish the LRU tail.
        // Insertions/deletions/evictions still call `persistIndex` directly
        // and are unaffected by this counter.
        pendingReadFlushes += 1
        if pendingReadFlushes >= readFlushBatchSize {
            do {
                try persistIndex(durable: false)
                pendingReadFlushes = 0
            } catch {
                // Keep the backlog so the next read can retry the best-effort
                // metadata flush instead of losing all pending access times.
            }
        }

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
    /// the privacy policy rejects it (authenticated request, `Cache-Control:
    /// private`, or `Set-Cookie` response with the corresponding flags off) or
    /// when the body exceeds ``PersistentResponseCacheConfiguration/maxEntryBytes``. Eviction runs
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

        // Body writes are detached so the actor doesn't block on flash I/O
        // for an entry that can be up to `maxEntryBytes`. `.atomic` rename
        // semantics make concurrent writes for the same key safe (later
        // rename wins) and SHA-256-derived `bodyFileName` means different
        // keys never share a destination. The actor still serializes the
        // index update + `persistIndex` that follows, so the on-disk and
        // in-memory views remain consistent.
        do {
            try await Self.writeBodyData(
                value.data,
                to: bodyURL,
                dataProtectionClass: configuration.dataProtectionClass
            )
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
        Self.applyDataProtection(configuration.dataProtectionClass, to: bodiesDirectoryURL, fileManager: fileManager)
        try? persistIndex()
    }

    private func shouldStore(key: ResponseCacheKey, response: CachedResponse) -> Bool {
        shouldStore(key: DiskKey(key), responseHeaders: response.headers)
    }

    private func shouldStore(key: DiskKey, responseHeaders: [String: String]) -> Bool {
        Self.shouldStore(key: key, responseHeaders: responseHeaders, configuration: configuration)
    }

    private func evictIfNeeded() {
        guard index.entries.count > configuration.maxEntries || totalBytes > configuration.maxBytes else {
            return
        }
        // Single sort then drain in LRU order via index advance. The previous
        // implementation re-scanned `entries` for `min(by:)` on every step
        // (O(N²)); using `removeFirst` would still pay an O(N) shift per
        // step. An incrementing cursor keeps the inner loop O(1) per victim,
        // so total work is O(N log N) for the sort + O(K) for K evictions.
        let sortedIDs = index.entries.keys.sorted { lhs, rhs in
            let lhsDate = index.entries[lhs]?.lastAccessedAt ?? .distantPast
            let rhsDate = index.entries[rhs]?.lastAccessedAt ?? .distantPast
            return lhsDate < rhsDate
        }
        var cursor = sortedIDs.startIndex
        while cursor < sortedIDs.endIndex,
            index.entries.count > configuration.maxEntries || totalBytes > configuration.maxBytes
        {
            let victimID = sortedIDs[cursor]
            cursor = sortedIDs.index(after: cursor)
            guard let victim = index.entries[victimID] else { continue }
            removeEntry(id: victimID, entry: victim)
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
        Self.removeBody(fileName: fileName, in: bodiesDirectoryURL, fileManager: fileManager)
    }

    private func persistIndex(durable: Bool = true) throws {
        try Self.persistIndex(
            index,
            to: indexURL,
            directoryURL: configuration.directoryURL,
            configuration: configuration,
            fileManager: fileManager,
            durable: durable
        )
        // Any successful flush — durable or not — clears the read-path
        // backlog because the encoded snapshot already includes the
        // accumulated `lastAccessedAt` updates.
        pendingReadFlushes = 0
    }

    private static func scrubPolicyRejectedEntriesOnOpen(
        _ loadedIndex: Index,
        configuration: PersistentResponseCacheConfiguration,
        indexURL: URL,
        bodiesDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> Index {
        var scrubbedIndex = loadedIndex
        let rejectedEntries = loadedIndex.entries.filter { _, entry in
            !shouldStore(key: entry.key, responseHeaders: entry.headers, configuration: configuration)
        }
        guard !rejectedEntries.isEmpty else { return loadedIndex }

        for (id, entry) in rejectedEntries {
            scrubbedIndex.entries.removeValue(forKey: id)
            removeBody(fileName: entry.bodyFileName, in: bodiesDirectoryURL, fileManager: fileManager)
        }
        try persistIndex(
            scrubbedIndex,
            to: indexURL,
            directoryURL: configuration.directoryURL,
            configuration: configuration,
            fileManager: fileManager
        )
        return scrubbedIndex
    }

    private static func enforceBudgetsOnOpen(
        _ loadedIndex: Index,
        configuration: PersistentResponseCacheConfiguration,
        indexURL: URL,
        bodiesDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> Index {
        var budgetedIndex = loadedIndex
        var didMutate = false

        for (id, entry) in loadedIndex.entries {
            let bodyURL = bodiesDirectoryURL.appendingPathComponent(entry.bodyFileName, isDirectory: false)
            guard let bodySize = fileSize(at: bodyURL, fileManager: fileManager) else {
                budgetedIndex.entries.removeValue(forKey: id)
                didMutate = true
                continue
            }
            if bodySize > configuration.maxEntryBytes {
                budgetedIndex.entries.removeValue(forKey: id)
                removeBody(fileName: entry.bodyFileName, in: bodiesDirectoryURL, fileManager: fileManager)
                didMutate = true
            }
        }

        let sortedIDs = budgetedIndex.entries.keys.sorted { lhs, rhs in
            let lhsDate = budgetedIndex.entries[lhs]?.lastAccessedAt ?? .distantPast
            let rhsDate = budgetedIndex.entries[rhs]?.lastAccessedAt ?? .distantPast
            return lhsDate < rhsDate
        }
        var cursor = sortedIDs.startIndex
        while cursor < sortedIDs.endIndex,
            budgetedIndex.entries.count > configuration.maxEntries
                || totalBytes(in: budgetedIndex) > configuration.maxBytes
        {
            let victimID = sortedIDs[cursor]
            cursor = sortedIDs.index(after: cursor)
            guard let victim = budgetedIndex.entries.removeValue(forKey: victimID) else { continue }
            removeBody(fileName: victim.bodyFileName, in: bodiesDirectoryURL, fileManager: fileManager)
            didMutate = true
        }

        if didMutate {
            try persistIndex(
                budgetedIndex,
                to: indexURL,
                directoryURL: configuration.directoryURL,
                configuration: configuration,
                fileManager: fileManager
            )
        }
        return budgetedIndex
    }

    private static func totalBytes(in index: Index) -> Int {
        index.entries.values.reduce(0) { $0 + $1.byteCost }
    }

    /// Read a body file off the actor's executor. Wrapping the synchronous
    /// `Data(contentsOf:)` in a detached task lets the cache actor service
    /// other requests while slow flash satisfies the read.
    private static func readBodyData(at url: URL) async throws -> Data {
        try await Task.detached { try Data(contentsOf: url) }.value
    }

    /// Write a body file off the actor's executor and apply the configured
    /// data-protection class. `FileManager.default` is documented as
    /// thread-safe for the read/write/attribute APIs we use here, so the
    /// detached task always uses the singleton — overriding the actor's
    /// `fileManager` only affects on-actor metadata, not body bytes.
    private static func writeBodyData(
        _ data: Data,
        to url: URL,
        dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass
    ) async throws {
        try await Task.detached {
            try data.write(to: url, options: .atomic)
            applyDataProtection(dataProtectionClass, to: url, fileManager: .default)
        }.value
    }

    private static func persistIndex(
        _ index: Index,
        to indexURL: URL,
        directoryURL: URL,
        configuration: PersistentResponseCacheConfiguration,
        fileManager: FileManager,
        durable: Bool = true
    ) throws {
        let data = try JSONEncoder.persistentCache.encode(index)
        try data.write(to: indexURL, options: .atomic)
        applyDataProtection(configuration.dataProtectionClass, to: indexURL, fileManager: fileManager)
        guard durable, configuration.persistenceFsyncPolicy == .always else { return }
        fsyncFile(at: indexURL)
        fsyncDirectory(at: directoryURL)
    }

    private static func removeBody(fileName: String, in bodiesDirectoryURL: URL, fileManager: FileManager) {
        let bodyURL = bodiesDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
        try? fileManager.removeItem(at: bodyURL)
    }

    private static func fileSize(at url: URL, fileManager: FileManager) -> Int? {
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return size.intValue
    }

    private static func shouldStore(
        key: DiskKey,
        responseHeaders: [String: String],
        configuration: PersistentResponseCacheConfiguration
    ) -> Bool {
        if !configuration.storesAuthenticatedResponses,
            containsSensitiveRequestHeader(key.headers)
        {
            return false
        }

        let cacheControl = cacheControlDirectives(in: responseHeaders)
        if cacheControl.contains("private") {
            return false
        }

        if !configuration.storesSetCookieResponses,
            responseHeaders.keys.contains(where: { $0.caseInsensitiveCompare("Set-Cookie") == .orderedSame })
        {
            return false
        }

        return true
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

    private static func containsSensitiveRequestHeader(_ headers: [String]) -> Bool {
        let sensitiveHeaderNames = ResponseCacheHeaderPolicy.sensitiveHeaderNames
        return headers.contains { header in
            guard let separator = header.firstIndex(of: ":") else { return false }
            let name = String(header[..<separator]).lowercased()
            return sensitiveHeaderNames.contains(name)
        }
    }

    private static func cacheControlDirectives(in headers: [String: String]) -> Set<String> {
        let combined =
            headers
            .filter { $0.key.caseInsensitiveCompare("Cache-Control") == .orderedSame }
            .map { $0.value }
            .joined(separator: ",")
        guard !combined.isEmpty else { return [] }
        return Set(
            HTTPListParser.split(combined)
                .map(HTTPListParser.directiveName(of:))
                .filter { !$0.isEmpty }
        )
    }

    private static func applyDataProtection(
        _ dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass,
        to url: URL,
        fileManager: FileManager
    ) {
        try? fileManager.setAttributes(
            [.protectionKey: dataProtectionClass.fileProtectionType],
            ofItemAtPath: url.path
        )
    }

    private static func applyDataProtectionToExistingCacheFiles(
        dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass,
        indexURL: URL,
        bodiesDirectoryURL: URL,
        fileManager: FileManager
    ) {
        if fileManager.fileExists(atPath: indexURL.path) {
            applyDataProtection(dataProtectionClass, to: indexURL, fileManager: fileManager)
        }

        guard
            let bodyURLs = try? fileManager.contentsOfDirectory(
                at: bodiesDirectoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }

        for bodyURL in bodyURLs {
            let isRegularFile =
                (try? bodyURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegularFile else { continue }
            applyDataProtection(dataProtectionClass, to: bodyURL, fileManager: fileManager)
        }
    }

    private static func loadIndex(
        from indexURL: URL,
        directoryURL: URL,
        dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass,
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
                    dataProtectionClass: dataProtectionClass,
                    fileManager: fileManager
                )
                return Index(version: formatVersion, entries: [:])
            }
            return index
        } catch {
            try resetCacheStorage(
                indexURL: indexURL,
                bodiesDirectoryURL: bodiesDirectoryURL,
                dataProtectionClass: dataProtectionClass,
                fileManager: fileManager
            )
            return Index(version: formatVersion, entries: [:])
        }
    }

    private static func resetCacheStorage(
        indexURL: URL,
        bodiesDirectoryURL: URL,
        dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass,
        fileManager: FileManager
    ) throws {
        try? fileManager.removeItem(at: indexURL)
        try? fileManager.removeItem(at: bodiesDirectoryURL)
        try fileManager.createDirectory(at: bodiesDirectoryURL, withIntermediateDirectories: true)
        applyDataProtection(dataProtectionClass, to: bodiesDirectoryURL, fileManager: fileManager)
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

private extension PersistentResponseCacheConfiguration.DataProtectionClass {
    var fileProtectionType: FileProtectionType {
        switch self {
        case .complete:
            return .complete
        case .completeUnlessOpen:
            return .completeUnlessOpen
        case .completeUntilFirstUserAuthentication:
            return .completeUntilFirstUserAuthentication
        case .none:
            return .none
        }
    }
}

private extension JSONDecoder {
    static var persistentCache: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
