import Darwin
import Foundation

package protocol DownloadTaskStore: Actor {
    func upsert(id: String, url: URL, destinationURL: URL, resumeData: Data?) async throws
    func updateResumeData(id: String, resumeData: Data?) async throws
    func remove(id: String) async throws
    func remove(ids: Set<String>) async throws
    func record(forID id: String) async -> DownloadTaskPersistence.Record?
    func allRecords() async -> [DownloadTaskPersistence.Record]
    func id(forURL url: URL?) async -> String?
    func prune(keeping ids: Set<String>) async throws
}

package actor DownloadTaskPersistence {
    package struct Record: Codable, Sendable {
        let id: String
        let url: URL
        let destinationURL: URL
        let resumeData: Data?

        package init(id: String, url: URL, destinationURL: URL, resumeData: Data? = nil) {
            self.id = id
            self.url = url
            self.destinationURL = destinationURL
            self.resumeData = resumeData
        }
    }

    private let store: any DownloadTaskStore

    package init(
        sessionIdentifier: String,
        fileManager: sending FileManager = .default,
        baseDirectoryURL: URL? = nil,
        fsyncPolicy: DownloadConfiguration.PersistenceFsyncPolicy = .onCheckpoint,
        compactionPolicy: DownloadConfiguration.PersistenceCompactionPolicy = .default,
        fsync: @escaping @Sendable (Int32) -> Int32 = Darwin.fsync
    ) {
        self.store = AppendLogDownloadTaskStore(
            sessionIdentifier: sessionIdentifier,
            fileManager: fileManager,
            baseDirectoryURL: baseDirectoryURL,
            fsyncPolicy: fsyncPolicy,
            compactionPolicy: compactionPolicy,
            fsync: fsync
        )
    }

    package init(store: any DownloadTaskStore) {
        self.store = store
    }

    package func upsert(id: String, url: URL, destinationURL: URL, resumeData: Data? = nil) async throws {
        try await store.upsert(id: id, url: url, destinationURL: destinationURL, resumeData: resumeData)
    }

    package func updateResumeData(id: String, resumeData: Data?) async throws {
        try await store.updateResumeData(id: id, resumeData: resumeData)
    }

    package func remove(id: String) async throws {
        try await store.remove(id: id)
    }

    /// Bulk remove a set of IDs in a single mutate, taking the directory
    /// lock once and emitting one fsync regardless of `ids.count`. Used by
    /// `DownloadManager.cancelAll()` to avoid the N×lock + N×fsync cost of
    /// looping `remove(id:)` under cancel storms.
    package func remove(ids: Set<String>) async throws {
        guard !ids.isEmpty else { return }
        try await store.remove(ids: ids)
    }

    package func record(forID id: String) async -> Record? {
        await store.record(forID: id)
    }

    package func allRecords() async -> [Record] {
        await store.allRecords()
    }

    package func id(forURL url: URL?) async -> String? {
        await store.id(forURL: url)
    }

    package func prune(keeping ids: Set<String>) async throws {
        try await store.prune(keeping: ids)
    }
}

package actor AppendLogDownloadTaskStore: DownloadTaskStore {
    // Visibility note: nested types and static helpers are intentionally
    // `internal` (default) rather than `private` so the extension files
    // (`AppendLogDownloadTaskStore+IO.swift`, `+LogReplay.swift`,
    // `+Checkpoint.swift`, `+Quarantine.swift`) can reference them. They
    // remain module-private — the package boundary is enforced by the
    // actor itself being `package`.
    struct Envelope: Codable, Sendable {
        let version: Int
        let records: [String: DownloadTaskPersistence.Record]
        let orderedRecordIDs: [String]?

        init(
            version: Int = 1,
            records: [String: DownloadTaskPersistence.Record],
            orderedRecordIDs: [String]? = nil
        ) {
            self.version = version
            self.records = records
            self.orderedRecordIDs = orderedRecordIDs
        }
    }

    enum EventKind: String, Codable, Sendable {
        case upsert
        case remove
    }

    struct Event: Codable, Sendable {
        let sequence: Int64
        let timestamp: Date
        let kind: EventKind
        let taskID: String
        let url: URL?
        let destinationURL: URL?
        let resumeData: Data?
    }

    struct StoreState: Sendable {
        var records: [String: DownloadTaskPersistence.Record]
        // Reverse index from source URL → ordered task ids so `id(forURL:)`
        // is O(1) yet still correct when multiple records share a URL. The
        // last element wins for `id(forURL:)`, which models the documented
        // "most recently upserted" semantic; intermediate ids remain
        // discoverable via `record(forID:)` and survive removal of any
        // sibling. Rebuilt on load and kept in sync on every mutate so it
        // never lies about authoritative state.
        var urlToID: [URL: [String]]
        var nextSequence: Int64
        var logEventCount: Int
        var tombstoneCount: Int
        var logSize: UInt64
    }

    private let fileManager: FileManager
    private let directoryURL: URL
    private let checkpointURL: URL
    private let logURL: URL
    private let lockURL: URL
    private let fsyncPolicy: DownloadConfiguration.PersistenceFsyncPolicy
    private let compactionPolicy: DownloadConfiguration.PersistenceCompactionPolicy
    private let fsync: @Sendable (Int32) -> Int32
    private var state: StoreState

    package init(
        sessionIdentifier: String,
        fileManager: sending FileManager = .default,
        baseDirectoryURL: URL? = nil,
        fsyncPolicy: DownloadConfiguration.PersistenceFsyncPolicy = .onCheckpoint,
        compactionPolicy: DownloadConfiguration.PersistenceCompactionPolicy = .default,
        fsync: @escaping @Sendable (Int32) -> Int32 = Darwin.fsync
    ) {
        let baseDirectory = baseDirectoryURL ?? Self.defaultBaseDirectory(fileManager: fileManager)
        let persistenceRootURL =
            baseDirectory
            .appendingPathComponent("InnoNetworkDownload", isDirectory: true)
        let directoryURL =
            persistenceRootURL
            .appendingPathComponent(sessionIdentifier, isDirectory: true)
        let checkpointURL = directoryURL.appendingPathComponent("checkpoint.json", isDirectory: false)
        let logURL = directoryURL.appendingPathComponent("events.log", isDirectory: false)
        let lockURL = directoryURL.appendingPathComponent(".lock", isDirectory: false)
        let initialState: StoreState

        do {
            try Self.ensureDirectoryExists(at: persistenceRootURL, fileManager: fileManager)
            try Self.ensureDirectoryExists(at: directoryURL, fileManager: fileManager)
            DownloadOwnedStorageProtection.apply(to: persistenceRootURL, fileManager: fileManager)
            DownloadOwnedStorageProtection.apply(to: directoryURL, fileManager: fileManager)
            initialState = try Self.withDirectoryLock(lockURL: lockURL, fileManager: fileManager) {
                try Self.loadState(
                    directoryURL: directoryURL,
                    checkpointURL: checkpointURL,
                    logURL: logURL,
                    fileManager: fileManager
                )
            }
        } catch {
            Self.quarantineFileIfNeeded(checkpointURL, fileManager: fileManager)
            Self.quarantineFileIfNeeded(logURL, fileManager: fileManager)
            initialState = StoreState(
                records: [:],
                urlToID: [:],
                nextSequence: 0,
                logEventCount: 0,
                tombstoneCount: 0,
                logSize: 0
            )
        }

        // Resource attributes can be stripped by restores or external file
        // management. Reapply them whenever the store reopens, including when
        // no mutation follows this initialization.
        for url in [checkpointURL, logURL, lockURL]
        where fileManager.fileExists(atPath: url.path) {
            DownloadOwnedStorageProtection.apply(to: url, fileManager: fileManager)
        }

        self.fileManager = fileManager
        self.directoryURL = directoryURL
        self.checkpointURL = checkpointURL
        self.logURL = logURL
        self.lockURL = lockURL
        self.fsyncPolicy = fsyncPolicy
        self.compactionPolicy = compactionPolicy
        self.fsync = fsync
        self.state = initialState
    }

    package func upsert(id: String, url: URL, destinationURL: URL, resumeData: Data?) async throws {
        try await mutate {
            // Drop any reverse-index entry that was previously tied to a
            // different URL for this id; the new URL gets the id appended
            // below so `id(forURL:)` keeps returning the most-recent upsert.
            if let existing = $0.records[id], existing.url != url {
                Self.removeIDFromIndex(state: &$0, url: existing.url, id: id)
            }
            $0.records[id] = DownloadTaskPersistence.Record(
                id: id,
                url: url,
                destinationURL: destinationURL,
                resumeData: resumeData
            )
            Self.appendIDToIndex(state: &$0, url: url, id: id)
            return Event(
                sequence: $0.nextSequence,
                timestamp: .now,
                kind: .upsert,
                taskID: id,
                url: url,
                destinationURL: destinationURL,
                resumeData: resumeData
            )
        }
    }

    package func updateResumeData(id: String, resumeData: Data?) async throws {
        try await mutate {
            guard let existing = $0.records[id] else { return [] }
            $0.records[id] = DownloadTaskPersistence.Record(
                id: existing.id,
                url: existing.url,
                destinationURL: existing.destinationURL,
                resumeData: resumeData
            )
            return [
                Event(
                    sequence: $0.nextSequence,
                    timestamp: .now,
                    kind: .upsert,
                    taskID: existing.id,
                    url: existing.url,
                    destinationURL: existing.destinationURL,
                    resumeData: resumeData
                )
            ]
        }
    }

    package func remove(id: String) async throws {
        guard state.records[id] != nil else { return }
        try await mutate {
            if let existing = $0.records.removeValue(forKey: id) {
                Self.removeIDFromIndex(state: &$0, url: existing.url, id: id)
            }
            $0.tombstoneCount += 1
            return Event(
                sequence: $0.nextSequence,
                timestamp: .now,
                kind: .remove,
                taskID: id,
                url: nil,
                destinationURL: nil,
                resumeData: nil
            )
        }
    }

    package func remove(ids: Set<String>) async throws {
        guard !ids.isEmpty else { return }
        // Presence filtering must happen inside `mutate` against the
        // freshly re-read disk state. The actor-local `state` snapshot can
        // be stale relative to upserts that another store instance flushed
        // between the actor read and the directory lock — pre-filtering
        // there would silently drop those concurrently-added records and
        // resurrect cancelled downloads on the next restore.
        try await mutate { state in
            var removed: [String] = []
            removed.reserveCapacity(ids.count)
            for id in ids {
                if let existing = state.records.removeValue(forKey: id) {
                    Self.removeIDFromIndex(state: &state, url: existing.url, id: id)
                    removed.append(id)
                }
            }
            guard !removed.isEmpty else { return [] }
            state.tombstoneCount += removed.count
            return removed.enumerated().map { index, id in
                Event(
                    sequence: state.nextSequence + Int64(index),
                    timestamp: .now,
                    kind: .remove,
                    taskID: id,
                    url: nil,
                    destinationURL: nil,
                    resumeData: nil
                )
            }
        }
    }

    package func record(forID id: String) async -> DownloadTaskPersistence.Record? {
        state.records[id]
    }

    package func allRecords() async -> [DownloadTaskPersistence.Record] {
        Array(state.records.values)
    }

    package func id(forURL url: URL?) async -> String? {
        guard let url else { return nil }
        return state.urlToID[url]?.last
    }

    static func appendIDToIndex(state: inout StoreState, url: URL, id: String) {
        var ids = state.urlToID[url] ?? []
        ids.removeAll { $0 == id }
        ids.append(id)
        state.urlToID[url] = ids
    }

    private static func removeIDFromIndex(state: inout StoreState, url: URL, id: String) {
        guard var ids = state.urlToID[url] else { return }
        ids.removeAll { $0 == id }
        if ids.isEmpty {
            state.urlToID.removeValue(forKey: url)
        } else {
            state.urlToID[url] = ids
        }
    }

    package func prune(keeping ids: Set<String>) async throws {
        try await mutate { state in
            let staleIDs = state.records.keys.filter { !ids.contains($0) }
            guard !staleIDs.isEmpty else { return [] }

            for staleID in staleIDs {
                if let existing = state.records.removeValue(forKey: staleID) {
                    Self.removeIDFromIndex(state: &state, url: existing.url, id: staleID)
                }
            }
            state.tombstoneCount += staleIDs.count
            return staleIDs.enumerated().map { index, staleID in
                Event(
                    sequence: state.nextSequence + Int64(index),
                    timestamp: .now,
                    kind: .remove,
                    taskID: staleID,
                    url: nil,
                    destinationURL: nil,
                    resumeData: nil
                )
            }
        }
    }

    private func mutate(_ transform: (inout StoreState) -> Event) async throws {
        try await mutate { state in [transform(&state)] }
    }

    /// Read-after-write consistency note: while `mutate` is awaiting
    /// `awaitDirectoryLock` (after the descriptor was opened but before the
    /// flock returns) actor isolation is released, so concurrent reads
    /// (`id(forURL:)`, `record(forID:)`, `allRecords()`) observe the
    /// in-memory `state` from before this mutation. The on-disk log is
    /// still serialized by the inter-process flock, but in-process readers
    /// must accept that an in-flight mutation is not yet visible. Callers
    /// that need read-after-write within a single process should sequence
    /// reads after the awaited `mutate`.
    private func mutate(_ transform: (inout StoreState) -> [Event]) async throws {
        let fsyncPolicy = self.fsyncPolicy
        let compactionPolicy = self.compactionPolicy
        let fsync = self.fsync
        let descriptorRaw = try Self.openLockDescriptor(lockURL: lockURL, fileManager: fileManager)
        let descriptor = try await Self.awaitDirectoryLock(descriptor: descriptorRaw, timeout: 10)
        defer { Self.releaseDirectoryLock(descriptor) }
        var diskState = try Self.loadState(
            directoryURL: directoryURL,
            checkpointURL: checkpointURL,
            logURL: logURL,
            fileManager: fileManager
        )

        let events = transform(&diskState)
        guard !events.isEmpty else {
            state = diskState
            return
        }

        try Self.append(
            events: events,
            to: logURL,
            fileManager: fileManager,
            fsyncPolicy: fsyncPolicy,
            fsync: fsync
        )
        diskState.logEventCount += events.count
        diskState.logSize = Self.fileSize(at: logURL, fileManager: fileManager)
        diskState.nextSequence += Int64(events.count)

        if Self.shouldCompact(state: diskState, policy: compactionPolicy) {
            try Self.writeCheckpoint(
                records: diskState.records,
                urlToID: diskState.urlToID,
                to: checkpointURL,
                fileManager: fileManager,
                fsyncPolicy: fsyncPolicy,
                fsync: fsync
            )
            try Self.resetLog(at: logURL, fileManager: fileManager)
            diskState.logEventCount = 0
            diskState.tombstoneCount = 0
            diskState.logSize = 0
        }

        state = diskState
    }

}
