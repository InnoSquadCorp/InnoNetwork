import Foundation

/// Snapshot of persistent response cache storage pressure and entry count.
///
/// Returned from ``PersistentResponseCache/statistics()`` so callers can
/// surface dashboards or back-pressure decisions without inspecting the
/// on-disk index directly.
public struct PersistentResponseCacheStatistics: Sendable, Equatable {
    /// Number of cached entries currently present in the index.
    public let entryCount: Int
    /// Sum of body byte counts across all currently indexed entries.
    public let byteCount: Int
    /// Configured upper bound on `entryCount`.
    public let maxEntries: Int
    /// Configured upper bound on `byteCount`.
    public let maxBytes: Int
    /// Cumulative count of ``PersistentResponseCache/get(_:)`` calls that
    /// returned a cached body in this process. Resets when the cache actor
    /// is reconstructed; not persisted to disk.
    public let hitCount: Int
    /// Cumulative count of ``PersistentResponseCache/get(_:)`` calls that
    /// returned `nil` in this process (no entry, body unreadable, body
    /// rejected by privacy policy, or body exceeded `maxEntryBytes`).
    public let missCount: Int
    /// Cumulative count of evictions or scrubs the actor has performed in
    /// this process across all reasons (`storageBudget`, `policyRejected`,
    /// `missingBody`, `entryTooLarge`, `unreferencedBody`). The drained
    /// ``PersistentResponseCacheTelemetryEvent/scrubbedEntries`` events
    /// retain the per-reason breakdown.
    public let evictionCount: Int

    /// Builds a statistics snapshot.
    ///
    /// - Parameters:
    ///   - entryCount: Number of indexed entries.
    ///   - byteCount: Total stored body bytes.
    ///   - maxEntries: Configured entry cap.
    ///   - maxBytes: Configured byte cap.
    ///   - hitCount: In-process count of cache hits since the actor was
    ///     constructed. Defaults to `0` for source compatibility with
    ///     callers that built statistics by hand before the metric existed.
    ///   - missCount: In-process count of cache misses since the actor was
    ///     constructed. Defaults to `0` for source compatibility.
    ///   - evictionCount: In-process count of evicted/scrubbed entries
    ///     since the actor was constructed. Defaults to `0` for source
    ///     compatibility.
    public init(
        entryCount: Int,
        byteCount: Int,
        maxEntries: Int,
        maxBytes: Int,
        hitCount: Int = 0,
        missCount: Int = 0,
        evictionCount: Int = 0
    ) {
        self.entryCount = entryCount
        self.byteCount = byteCount
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
        self.hitCount = hitCount
        self.missCount = missCount
        self.evictionCount = evictionCount
    }
}

/// Reason a persistent cache entry was evicted or scrubbed.
public enum PersistentResponseCacheEvictionReason: String, Sendable, Equatable {
    /// Entry removed because the cache exceeded `maxBytes` or `maxEntries`.
    case storageBudget
    /// Entry removed because it no longer satisfies the active privacy
    /// policy (for example, an authenticated response in a configuration
    /// that disables `storesAuthenticatedResponses`).
    case policyRejected
    /// Entry removed because its body file is missing from disk.
    case missingBody
    /// Entry removed because its body exceeds `maxEntryBytes`.
    case entryTooLarge
    /// Entry removed because a body file on disk was not referenced by any
    /// surviving index entry.
    case unreferencedBody
}

/// Operational event emitted by ``PersistentResponseCache``.
public enum PersistentResponseCacheTelemetryEvent: Sendable, Equatable {
    /// One or more entries were scrubbed during cache open, write, or
    /// budget enforcement.
    ///
    /// - Parameters:
    ///   - reason: Why the entries were removed.
    ///   - count: Number of entries scrubbed in this batch.
    ///   - byteCount: Sum of body bytes reclaimed in this batch.
    case scrubbedEntries(reason: PersistentResponseCacheEvictionReason, count: Int, byteCount: Int)
}
