import Foundation
import InnoNetwork
import OSLog

/// Persistent on-disk implementation of ``ResponseCache``.
///
/// Stores response bodies in a flat directory keyed by SHA-256 hashes of the
/// canonical `(method, url, vary)` tuple. Survives process restarts and app
/// upgrades; corrupt or unknown-version indexes are recovered by deleting the
/// cache's own subtree (never the user-supplied directory root).
///
/// The cache enforces a synchronous LRU bound on every write so the disk
/// footprint stays within the configured byte and entry budgets.
///
/// ## Reentrancy invariant
///
/// The actor intentionally performs body-file I/O outside actor isolation.
/// After each suspension point it re-checks that the index entry still points
/// at the same body file before returning or committing metadata. This keeps
/// concurrent `get`, `set`, `remove`, and trim operations from returning a
/// stale body after another task replaced or evicted the entry while disk I/O
/// was in flight.
///
/// ## RFC 9111 scope
///
/// This cache is a storage layer, not a complete RFC 9111 implementation by
/// itself. `RequestExecutor` applies the default write-side guardrails
/// (`no-store`, `private`, `Vary: *`, and unsafe-method target URI
/// invalidation) before it calls into ``ResponseCache``. Direct calls to
/// ``set(_:_:)`` still use only this actor's conservative persistence policy.
///
/// Callers that need RFC 9111 directive semantics should wrap their
/// policy with ``ResponseCachePolicy/rfc9111Compliant(wrapping:)``. The
/// adapter implements the directive subset documented in
/// `docs/rfcs/RFC9111-Compliance.md` (`no-store`, `must-revalidate`, and
/// `max-age` clamping) on top of the wrapped policy without changing this
/// storage layer.
public actor PersistentResponseCache: ResponseCache {
    static let formatVersion = 2
    static let logger = Logger(subsystem: "innosquad.network", category: "PersistentResponseCache")

    // Visibility note: nested types and static helpers are intentionally
    // module-internal (no `private`/`fileprivate`) so the extension files
    // (`PersistentResponseCache+OpenPipeline.swift`, `+IO.swift`,
    // `+Policy.swift`) can reference them. The actor itself stays `public`,
    // but these helpers remain module-private.
    struct DiskKey: Codable, Hashable, Sendable {
        let method: String
        let url: String
        let headers: [String]

        init(_ key: ResponseCacheKey, normalizer: PersistentCacheDiskKeyNormalizer) {
            self.method = key.method
            self.url = key.url
            self.headers = normalizer.normalizeHeaders(key.headers)
        }

        init(method: String, url: String, headers: [String]) {
            self.method = method
            self.url = url
            self.headers = headers
        }
    }

    struct VariantDiskKey: Codable, Hashable, Sendable {
        let key: DiskKey
        let varyHeaders: [String: String?]
    }

    struct Index: Codable, Sendable {
        var version: Int
        var entries: [String: Entry]
    }

    struct Entry: Codable, Sendable {
        var key: DiskKey
        let statusCode: Int
        let headers: [String: String]
        let storedAt: Date
        let requiresRevalidation: Bool
        let varyHeaders: [String: String?]?
        let bodyFileName: String
        let byteCost: Int
        var lastAccessedAt: Date
    }

    struct OpenResult: Sendable {
        var index: Index
        var telemetryEvents: [PersistentResponseCacheTelemetryEvent]
    }

    private let configuration: PersistentResponseCacheConfiguration
    private let fileManager: FileManager
    private let bodiesDirectoryURL: URL
    private let indexURL: URL
    private let keyNormalizer: PersistentCacheDiskKeyNormalizer
    private let identifierEncoder = JSONEncoder.persistentCache
    private var index: Index
    private var entryIDsByDiskKey: [DiskKey: Set<String>] = [:]
    private var runningTotalBytes: Int
    private var telemetryEvents: [PersistentResponseCacheTelemetryEvent]
    /// Cumulative cache hits since this actor was constructed.
    /// Saturates at `Int.max` rather than overflowing.
    private var hitCount: Int = 0
    /// Cumulative cache misses since this actor was constructed.
    /// Saturates at `Int.max` rather than overflowing.
    private var missCount: Int = 0
    /// Cumulative evicted/scrubbed entries since this actor was
    /// constructed, summed across every reason in
    /// ``PersistentResponseCacheEvictionReason``. Saturates at
    /// `Int.max` rather than overflowing.
    private var evictionCount: Int = 0
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
    /// Throws if the directory cannot be created or the existing HMAC key
    /// cannot currently be read. A key read failure is surfaced without
    /// deleting cache state because protected data or file access can be
    /// temporarily unavailable. Unknown index versions and decode failures are
    /// not surfaced as errors — the cache resets its own state and continues,
    /// so a corrupt cache from a prior version is safe to inherit.
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
        let keyResult = try PersistentCacheDiskKeyNormalizer.loadOrCreate(
            directoryURL: configuration.directoryURL,
            dataProtectionClass: configuration.dataProtectionClass,
            keyStorage: configuration.keyStorage,
            fileManager: fileManager
        )
        // If the existing HMAC key had the wrong length, or was missing while
        // cache state remained, we had to regenerate it. Any prior on-disk
        // entries are now keyed under a different HMAC and would never
        // lookup-match again, so we reset the index and bodies together to
        // keep the cache self-consistent. Read failures throw before this point
        // and leave all existing files untouched.
        if keyResult.regenerated {
            try Self.resetCacheStorage(
                indexURL: indexURL,
                bodiesDirectoryURL: bodiesDirectoryURL,
                dataProtectionClass: configuration.dataProtectionClass,
                fileManager: fileManager
            )
        }
        self.keyNormalizer = keyResult.normalizer
        let loadResult = try Self.loadIndex(
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
        let reindexed = try Self.reindexVaryVariantsOnOpen(
            loadResult.index,
            encoder: identifierEncoder
        )
        if Set(reindexed.entries.keys) != Set(loadResult.index.entries.keys) {
            try Self.persistIndex(
                reindexed,
                to: indexURL,
                directoryURL: configuration.directoryURL,
                configuration: configuration,
                fileManager: fileManager
            )
        }
        let policyScrubResult = try Self.scrubPolicyRejectedEntriesOnOpen(
            reindexed,
            configuration: configuration,
            indexURL: indexURL,
            bodiesDirectoryURL: bodiesDirectoryURL,
            fileManager: fileManager
        )
        let budgetResult = try Self.enforceBudgetsOnOpen(
            policyScrubResult.index,
            configuration: configuration,
            indexURL: indexURL,
            bodiesDirectoryURL: bodiesDirectoryURL,
            fileManager: fileManager
        )
        let scrubbedBodies = Self.scrubUnreferencedBodiesOnOpen(
            budgetResult.index,
            bodiesDirectoryURL: bodiesDirectoryURL,
            fileManager: fileManager
        )
        self.index = budgetResult.index
        self.entryIDsByDiskKey = Self.makeEntryIDsByDiskKey(from: budgetResult.index)
        self.runningTotalBytes = Self.totalBytes(in: budgetResult.index)
        var telemetry = loadResult.telemetryEvents
        telemetry.append(contentsOf: policyScrubResult.telemetryEvents)
        telemetry.append(contentsOf: budgetResult.telemetryEvents)
        if scrubbedBodies > 0 {
            telemetry.append(.scrubbedEntries(reason: .unreferencedBody, count: scrubbedBodies, byteCount: 0))
        }
        self.telemetryEvents = telemetry
        // Seed the eviction counter from any scrubs the open-time pipeline
        // already performed so `statistics().evictionCount` reflects the
        // entire actor lifetime rather than only post-init activity.
        self.evictionCount = telemetry.reduce(into: 0) { partial, event in
            switch event {
            case .scrubbedEntries(_, let count, _):
                if partial > Int.max - count {
                    partial = .max
                } else {
                    partial += count
                }
            }
        }
    }

    /// Look up a cached response for `key`. Returns `nil` on miss or when the
    /// body file cannot be read (the index entry is dropped). The recorded
    /// `lastAccessedAt` is best-effort persisted; a failure to write the
    /// index never demotes a successful read to a miss.
    public func get(_ key: ResponseCacheKey) async -> CachedResponse? {
        let diskKey = DiskKey(key, normalizer: keyNormalizer)
        guard let selection = matchingEntry(for: diskKey) else {
            recordMiss()
            return nil
        }
        let id = selection.0
        var entry = selection.1
        guard shouldStore(key: entry.key, responseHeaders: entry.headers) else {
            scrubEntry(id: id, entry: entry, reason: .policyRejected)
            try? persistIndex()
            recordMiss()
            return nil
        }
        let bodyURL = bodiesDirectoryURL.appendingPathComponent(entry.bodyFileName, isDirectory: false)

        // Body reads (potentially up to `maxEntryBytes`, default 5 MB) run on
        // a detached task so the actor can process unrelated requests while
        // slow flash blocks the read. The actor remains the single writer of
        // `index`. Because actors are reentrant across the await, the read
        // result is applied only if the same body file is still the current
        // entry when the actor resumes.
        let data: Data
        do {
            data = try await Self.readBodyData(at: bodyURL)
        } catch {
            if isCurrentEntry(id: id, entry: entry) {
                scrubEntry(id: id, entry: entry, reason: .missingBody)
                try? persistIndex()
            }
            recordMiss()
            return nil
        }
        guard data.count <= configuration.maxEntryBytes else {
            if isCurrentEntry(id: id, entry: entry) {
                scrubEntry(id: id, entry: entry, reason: .entryTooLarge)
                try? persistIndex()
            }
            recordMiss()
            return nil
        }
        guard isCurrentEntry(id: id, entry: entry) else {
            recordMiss()
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

        recordHit()
        return CachedResponse(
            data: data,
            statusCode: entry.statusCode,
            headers: entry.headers,
            storedAt: entry.storedAt,
            requiresRevalidation: entry.requiresRevalidation,
            varyHeaders: entry.varyHeaders
        )
    }

    /// Saturating-add a cache hit to the metric counter. Wrapping at
    /// ``Int/max`` keeps the counter monotonic even for long-lived cache
    /// actors.
    private func recordHit() {
        if hitCount < .max {
            hitCount += 1
        }
    }

    /// Saturating-add a cache miss to the metric counter.
    private func recordMiss() {
        if missCount < .max {
            missCount += 1
        }
    }

    /// Saturating-add `count` evictions to the metric counter. Used by
    /// every code path that emits a
    /// ``PersistentResponseCacheTelemetryEvent/scrubbedEntries`` event, so
    /// the eviction count stays in sync with the per-reason telemetry log.
    private func recordEviction(count: Int) {
        guard count > 0 else { return }
        if evictionCount > Int.max - count {
            evictionCount = .max
        } else {
            evictionCount += count
        }
    }

    private func recordScrub(
        reason: PersistentResponseCacheEvictionReason,
        count: Int = 1,
        byteCount: Int
    ) {
        guard count > 0 else { return }
        telemetryEvents.append(
            .scrubbedEntries(
                reason: reason,
                count: count,
                byteCount: byteCount
            )
        )
        recordEviction(count: count)
    }

    /// Store `value` under `key`. Drops the entry instead of storing it when
    /// the privacy policy rejects it (authenticated request, `Cache-Control:
    /// private`, or `Set-Cookie` response with the corresponding flags off) or
    /// when the body exceeds ``PersistentResponseCacheConfiguration/maxEntryBytes``. Eviction runs
    /// synchronously to keep the on-disk footprint within budget.
    public func set(_ key: ResponseCacheKey, _ value: CachedResponse) async {
        guard evaluateStorePolicy(key: key, response: value), value.data.count <= configuration.maxEntryBytes else {
            await invalidate(key)
            return
        }

        let diskKey = DiskKey(key, normalizer: keyNormalizer)
        let id: String
        do {
            id = try identifier(for: diskKey, varyHeaders: value.varyHeaders)
        } catch {
            Self.logger.error(
                "persistent_cache_identifier_failed operation=set url=\(key.url, privacy: .private) error=\(String(describing: error), privacy: .private)"
            )
            return
        }
        let bodyFileName = "\(id)-\(UUID().uuidString).body"
        let bodyURL = bodiesDirectoryURL.appendingPathComponent(bodyFileName, isDirectory: false)
        let headerByteCost: Int = value.headers.reduce(0) { partialResult, header in
            partialResult + header.key.utf8.count + header.value.utf8.count
        }
        let varyHeaderByteCost: Int =
            value.varyHeaders?.reduce(0) { partialResult, header in
                partialResult + header.key.utf8.count + (header.value?.utf8.count ?? 0)
            } ?? 0
        let byteCost = value.data.count + headerByteCost + varyHeaderByteCost
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
        // semantics plus a unique body filename let us stage the new bytes
        // without overwriting the previous body. The index is updated only
        // after the staged body exists. The actor is reentrant while the
        // detached write is suspended, so the rollback snapshot is captured
        // only after the await resumes and includes any intervening mutations.
        var rollbackIndex: Index?
        var rollbackRunningTotalBytes: Int?
        do {
            try await Self.writeBodyData(
                value.data,
                to: bodyURL,
                dataProtectionClass: configuration.dataProtectionClass
            )
            rollbackIndex = index
            rollbackRunningTotalBytes = runningTotalBytes
            let replacedEntry = index.entries[id]
            let replacedBodyFileName = replacedEntry?.bodyFileName
            if let old = replacedEntry {
                runningTotalBytes -= old.byteCost
            }
            index.entries[id] = entry
            replaceEntryReference(id: id, old: replacedEntry, new: entry)
            runningTotalBytes += entry.byteCost
            var removableBodies = evictIfNeeded()
            let evictedBytes = removableBodies.reduce(0) { $0 + $1.byteCost }
            if !removableBodies.isEmpty {
                telemetryEvents.append(
                    .scrubbedEntries(
                        reason: .storageBudget,
                        count: removableBodies.count,
                        byteCount: evictedBytes
                    )
                )
                recordEviction(count: removableBodies.count)
            }
            if let replacedBodyFileName, replacedBodyFileName != bodyFileName {
                removableBodies.append((fileName: replacedBodyFileName, byteCost: 0))
            }
            try persistIndex()
            for fileName in removableBodies.map(\.fileName) {
                removeBody(fileName: fileName)
            }
        } catch {
            if let rollbackIndex, let rollbackRunningTotalBytes {
                index = rollbackIndex
                entryIDsByDiskKey = Self.makeEntryIDsByDiskKey(from: rollbackIndex)
                runningTotalBytes = rollbackRunningTotalBytes
            }
            removeBody(fileName: bodyFileName)
            Self.logger.error(
                "persistent_cache_set_failed url=\(key.url, privacy: .private) error=\(String(describing: error), privacy: .private)"
            )
        }
    }

    /// Remove the entry for `key` from the index and delete its body file.
    public func invalidate(_ key: ResponseCacheKey) async {
        let diskKey = DiskKey(key, normalizer: keyNormalizer)
        let matches = entryIDs(matching: diskKey)
        guard !matches.isEmpty else { return }
        for (id, entry) in matches {
            removeEntry(id: id, entry: entry)
        }
        try? persistIndex()
    }

    /// Remove every persisted entry whose normalized target URI matches
    /// `targetURI`, regardless of request method or Vary/header dimensions.
    public func invalidateTargetURI(_ targetURI: String) async {
        let normalizedTargetURI = ResponseCacheKey.normalizedTargetURI(targetURI)
        let matches = index.entries.filter { _, entry in
            entry.key.url == normalizedTargetURI
        }
        guard !matches.isEmpty else { return }

        for (id, entry) in matches {
            removeEntry(id: id, entry: entry)
        }
        try? persistIndex()
    }

    /// Clear all entries. Resets the index and recreates the bodies directory.
    /// The user-supplied configuration directory itself is left in place.
    public func removeAll() async {
        index.entries.removeAll()
        entryIDsByDiskKey.removeAll(keepingCapacity: true)
        runningTotalBytes = 0
        try? fileManager.removeItem(at: bodiesDirectoryURL)
        try? fileManager.createDirectory(at: bodiesDirectoryURL, withIntermediateDirectories: true)
        Self.applyDataProtection(configuration.dataProtectionClass, to: bodiesDirectoryURL, fileManager: fileManager)
        try? persistIndex()
    }

    private func evaluateStorePolicy(key: ResponseCacheKey, response: CachedResponse) -> Bool {
        Self.shouldStore(
            key: DiskKey(key, normalizer: keyNormalizer),
            responseHeaders: response.headers,
            configuration: configuration
        )
    }

    /// Current storage pressure snapshot, including in-process hit, miss,
    /// and eviction counts.
    public func statistics() -> PersistentResponseCacheStatistics {
        PersistentResponseCacheStatistics(
            entryCount: index.entries.count,
            byteCount: runningTotalBytes,
            maxEntries: configuration.maxEntries,
            maxBytes: configuration.maxBytes,
            hitCount: hitCount,
            missCount: missCount,
            evictionCount: evictionCount
        )
    }

    /// Returns accumulated operational events without clearing them.
    public func telemetrySnapshot() -> [PersistentResponseCacheTelemetryEvent] {
        telemetryEvents
    }

    /// Returns accumulated operational events and clears the in-memory buffer.
    public func drainTelemetryEvents() -> [PersistentResponseCacheTelemetryEvent] {
        let events = telemetryEvents
        telemetryEvents.removeAll(keepingCapacity: true)
        return events
    }

    private func shouldStore(key: DiskKey, responseHeaders: [String: String]) -> Bool {
        Self.shouldStore(key: key, responseHeaders: responseHeaders, configuration: configuration)
    }

    private func evictIfNeeded() -> [(fileName: String, byteCost: Int)] {
        guard index.entries.count > configuration.maxEntries || runningTotalBytes > configuration.maxBytes else {
            return []
        }
        var removedBodies: [(fileName: String, byteCost: Int)] = []
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
            index.entries.count > configuration.maxEntries || runningTotalBytes > configuration.maxBytes
        {
            let victimID = sortedIDs[cursor]
            cursor = sortedIDs.index(after: cursor)
            guard let victim = index.entries[victimID] else { continue }
            if let removed = index.entries.removeValue(forKey: victimID) {
                runningTotalBytes -= removed.byteCost
                removeEntryReference(id: victimID, entry: removed)
                removedBodies.append((fileName: victim.bodyFileName, byteCost: victim.byteCost))
            }
        }
        return removedBodies
    }

    private func removeEntry(id: String, entry: Entry) {
        var bodyFileName = entry.bodyFileName
        if let removed = index.entries.removeValue(forKey: id) {
            runningTotalBytes -= removed.byteCost
            removeEntryReference(id: id, entry: removed)
            bodyFileName = removed.bodyFileName
        }
        removeBody(fileName: bodyFileName)
    }

    private func scrubEntry(
        id: String,
        entry: Entry,
        reason: PersistentResponseCacheEvictionReason
    ) {
        removeEntry(id: id, entry: entry)
        recordScrub(reason: reason, byteCount: entry.byteCost)
    }

    private func isCurrentEntry(id: String, entry: Entry) -> Bool {
        index.entries[id]?.bodyFileName == entry.bodyFileName
    }

    private func matchingEntry(for diskKey: DiskKey) -> (String, Entry)? {
        let candidates =
            entryIDs(matching: diskKey)
            .sorted { lhs, rhs in
                if lhs.value.lastAccessedAt != rhs.value.lastAccessedAt {
                    return lhs.value.lastAccessedAt > rhs.value.lastAccessedAt
                }
                if lhs.value.storedAt != rhs.value.storedAt {
                    return lhs.value.storedAt > rhs.value.storedAt
                }
                return lhs.key > rhs.key
            }
        return candidates.first { _, entry in
            Self.varySnapshot(entry.varyHeaders, matches: diskKey)
        }
    }

    private static func makeEntryIDsByDiskKey(from index: Index) -> [DiskKey: Set<String>] {
        index.entries.reduce(into: [:]) { partial, item in
            let (id, entry) = item
            partial[entry.key, default: []].insert(id)
        }
    }

    private func entryIDs(matching diskKey: DiskKey) -> [(key: String, value: Entry)] {
        guard let ids = entryIDsByDiskKey[diskKey] else { return [] }
        return ids.compactMap { id in
            index.entries[id].map { (key: id, value: $0) }
        }
    }

    private func replaceEntryReference(id: String, old: Entry?, new: Entry) {
        if let old {
            removeEntryReference(id: id, entry: old)
        }
        entryIDsByDiskKey[new.key, default: []].insert(id)
    }

    private func removeEntryReference(id: String, entry: Entry) {
        guard var ids = entryIDsByDiskKey[entry.key] else { return }
        ids.remove(id)
        if ids.isEmpty {
            entryIDsByDiskKey[entry.key] = nil
        } else {
            entryIDsByDiskKey[entry.key] = ids
        }
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

    private func identifier(for key: DiskKey) throws -> String {
        try Self.identifier(for: key, encoder: identifierEncoder)
    }

    private func identifier(for key: DiskKey, varyHeaders: [String: String?]?) throws -> String {
        try Self.identifier(for: key, varyHeaders: varyHeaders, encoder: identifierEncoder)
    }
}
