import Darwin
import Foundation
import InnoNetwork
import os

package protocol DownloadTaskStore: Actor {
    func upsert(id: String, url: URL, destinationURL: URL, resumeData: Data?) async throws
    func beginStart(
        id: String,
        url: URL,
        destinationURL: URL,
        mode: DownloadTaskPersistence.StartMode,
        retryCount: Int,
        totalRetryCount: Int
    ) async throws -> Bool
    func updateResumeData(
        id: String,
        resumeData: Data?,
        lifecycle: DownloadTaskPersistence.Record.Lifecycle
    ) async throws
    func transitionResumeState(
        id: String,
        from expectedLifecycle: DownloadTaskPersistence.Record.Lifecycle?,
        to lifecycle: DownloadTaskPersistence.Record.Lifecycle,
        resumeData: Data?
    ) async throws -> Bool
    func updateRetryState(
        id: String,
        retryCount: Int,
        totalRetryCount: Int,
        retryPlan: DownloadTaskPersistence.RetryPlan?
    ) async throws -> Bool
    func beginCommit(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata
    ) async throws -> Bool
    func finishCommit(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata
    ) async throws -> Bool
    func abandonCommit(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata?
    ) async throws -> Bool
    func acknowledgeCommitOutcome(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata,
        outcome: DownloadTaskPersistence.CommitOutcome
    ) async throws -> Bool
    func markTerminal(
        ids: Set<String>,
        inserting records: [DownloadTaskPersistence.Record]
    ) async throws
    func remove(id: String) async throws
    func remove(ids: Set<String>) async throws
    func record(forID id: String) async -> DownloadTaskPersistence.Record?
    func allRecords() async -> [DownloadTaskPersistence.Record]
    func id(forURL url: URL?) async -> String?
    func prune(keeping ids: Set<String>) async throws
}

package actor DownloadTaskPersistence {
    package enum CommitOutcome: String, Codable, Sendable, Equatable {
        case finished
        case abandoned
    }

    package struct CommitMetadata: Codable, Sendable, Equatable {
        package let stagingKey: String
        package let originalRequestURL: URL
        package let currentRequestURL: URL
        package let destinationURL: URL
        package let expectedByteCount: Int64
        package let payloadSHA256: String

        package init(
            stagingKey: String,
            originalRequestURL: URL,
            currentRequestURL: URL,
            destinationURL: URL,
            expectedByteCount: Int64,
            payloadSHA256: String
        ) {
            self.stagingKey = stagingKey
            self.originalRequestURL = originalRequestURL
            self.currentRequestURL = currentRequestURL
            self.destinationURL = destinationURL
            self.expectedByteCount = expectedByteCount
            self.payloadSHA256 = payloadSHA256
        }
    }

    package struct RetryNetworkSnapshot: Codable, Sendable, Equatable {
        package enum Status: String, Codable, Sendable, Equatable {
            case satisfied
            case unsatisfied
            case requiresConnection
        }

        package enum Interface: String, Codable, Sendable, Equatable, Hashable {
            case wifi
            case cellular
            case wiredEthernet
            case loopback
            case other
        }

        package let status: Status
        package let interfaceTypes: Set<Interface>

        package init(_ snapshot: NetworkSnapshot) {
            switch snapshot.status {
            case .satisfied:
                status = .satisfied
            case .unsatisfied:
                status = .unsatisfied
            case .requiresConnection:
                status = .requiresConnection
            }
            interfaceTypes = Set(
                snapshot.interfaceTypes.map { interface in
                    switch interface {
                    case .wifi: .wifi
                    case .cellular: .cellular
                    case .wiredEthernet: .wiredEthernet
                    case .loopback: .loopback
                    case .other: .other
                    }
                })
        }

        package var value: NetworkSnapshot {
            let reachability: NetworkReachabilityStatus =
                switch status {
                case .satisfied: .satisfied
                case .unsatisfied: .unsatisfied
                case .requiresConnection: .requiresConnection
                }
            let interfaces = Set(
                interfaceTypes.map { interface in
                    switch interface {
                    case .wifi: NetworkInterfaceType.wifi
                    case .cellular: NetworkInterfaceType.cellular
                    case .wiredEthernet: NetworkInterfaceType.wiredEthernet
                    case .loopback: NetworkInterfaceType.loopback
                    case .other: NetworkInterfaceType.other
                    }
                })
            return NetworkSnapshot(status: reachability, interfaceTypes: interfaces)
        }
    }

    package struct RetryPlan: Codable, Sendable, Equatable {
        package enum Phase: String, Codable, Sendable, Equatable {
            case waitingForNetwork
            case backoff
        }

        package let phase: Phase
        package let retryNotBefore: Date?
        package let networkBaseline: RetryNetworkSnapshot?
        package let networkWaitDeadline: Date?

        package init(
            phase: Phase,
            retryNotBefore: Date? = nil,
            networkBaseline: RetryNetworkSnapshot? = nil,
            networkWaitDeadline: Date? = nil
        ) {
            self.phase = phase
            self.retryNotBefore = retryNotBefore
            self.networkBaseline = networkBaseline
            self.networkWaitDeadline = networkWaitDeadline
        }

        package static func waitingForNetwork(
            baseline: NetworkSnapshot?,
            deadline: Date?
        ) -> Self {
            Self(
                phase: .waitingForNetwork,
                networkBaseline: baseline.map(RetryNetworkSnapshot.init),
                networkWaitDeadline: deadline
            )
        }

        package static func backoff(retryNotBefore: Date) -> Self {
            Self(phase: .backoff, retryNotBefore: retryNotBefore)
        }
    }

    package enum StartMode: Sendable {
        /// A newly-created logical download. Existing terminal intent is
        /// never reopened by this mode.
        case initial
        /// A retry admitted by the failure coordinator. This is a strict
        /// `retryPending -> active` compare-and-set.
        case automaticRetry
        /// An explicit public retry of a finalized failed task. This is the
        /// only mode allowed to deliberately reopen a terminal checkpoint.
        case manualRetry
    }

    package struct Record: Codable, Sendable {
        package enum Lifecycle: String, Codable, Sendable, Equatable {
            case active
            case pausing
            case paused
            case resuming
            case retryPending
            case committing
            case terminal

            var restoresAsPausedWithoutSystemTask: Bool {
                switch self {
                case .pausing, .paused, .resuming:
                    return true
                case .active, .retryPending, .committing, .terminal:
                    return false
                }
            }
        }

        let id: String
        let url: URL
        let destinationURL: URL
        let resumeData: Data?
        /// Optional for backward decoding of pre-5.0 checkpoints and log
        /// events. A legacy record with resume data is still treated paused.
        let lifecycle: Lifecycle?
        /// Optional for backward decoding. Present only while a retry plan is
        /// durable across suspension/termination.
        let retryCount: Int?
        let totalRetryCount: Int?
        /// Optional for backward decoding. Legacy retryPending records without
        /// a plan retain their historical immediate-retry behavior.
        let retryPlan: RetryPlan?
        /// Optional for backward decoding. Present while a staged completion
        /// is being committed and retained on its terminal checkpoint as
        /// bounded cleanup evidence.
        let commitMetadata: CommitMetadata?
        /// Optional for backward decoding. Terminal commit checkpoints retain
        /// whether the durable journal was installed or explicitly abandoned.
        let commitOutcome: CommitOutcome?

        package init(
            id: String,
            url: URL,
            destinationURL: URL,
            resumeData: Data? = nil,
            lifecycle: Lifecycle? = nil,
            retryCount: Int? = nil,
            totalRetryCount: Int? = nil,
            retryPlan: RetryPlan? = nil,
            commitMetadata: CommitMetadata? = nil,
            commitOutcome: CommitOutcome? = nil
        ) {
            self.id = id
            self.url = url
            self.destinationURL = destinationURL
            self.resumeData = resumeData
            self.lifecycle = lifecycle
            self.retryCount = retryCount
            self.totalRetryCount = totalRetryCount
            self.retryPlan = retryPlan
            self.commitMetadata = commitMetadata
            self.commitOutcome = commitOutcome
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

    package func beginStart(
        id: String,
        url: URL,
        destinationURL: URL,
        mode: StartMode,
        retryCount: Int,
        totalRetryCount: Int
    ) async throws -> Bool {
        try await store.beginStart(
            id: id,
            url: url,
            destinationURL: destinationURL,
            mode: mode,
            retryCount: retryCount,
            totalRetryCount: totalRetryCount
        )
    }

    package func updateResumeData(
        id: String,
        resumeData: Data?,
        lifecycle: Record.Lifecycle
    ) async throws {
        try await store.updateResumeData(id: id, resumeData: resumeData, lifecycle: lifecycle)
    }

    package func transitionResumeState(
        id: String,
        from expectedLifecycle: Record.Lifecycle?,
        to lifecycle: Record.Lifecycle,
        resumeData: Data?
    ) async throws -> Bool {
        try await store.transitionResumeState(
            id: id,
            from: expectedLifecycle,
            to: lifecycle,
            resumeData: resumeData
        )
    }

    package func transitionResumeState(
        id: String,
        fromAny expectedLifecycles: [Record.Lifecycle?],
        to lifecycle: Record.Lifecycle,
        resumeData: Data?
    ) async throws -> Bool {
        for expectedLifecycle in expectedLifecycles {
            if try await store.transitionResumeState(
                id: id,
                from: expectedLifecycle,
                to: lifecycle,
                resumeData: resumeData
            ) {
                return true
            }
        }
        return false
    }

    package func updateRetryState(
        id: String,
        retryCount: Int,
        totalRetryCount: Int,
        retryPlan: RetryPlan? = nil
    ) async throws -> Bool {
        try await store.updateRetryState(
            id: id,
            retryCount: retryCount,
            totalRetryCount: totalRetryCount,
            retryPlan: retryPlan
        )
    }

    package func beginCommit(
        id: String,
        metadata: CommitMetadata
    ) async throws -> Bool {
        try await store.beginCommit(id: id, metadata: metadata)
    }

    package func finishCommit(
        id: String,
        metadata: CommitMetadata
    ) async throws -> Bool {
        try await store.finishCommit(id: id, metadata: metadata)
    }

    package func abandonCommit(
        id: String,
        metadata: CommitMetadata?
    ) async throws -> Bool {
        try await store.abandonCommit(id: id, metadata: metadata)
    }

    package func acknowledgeCommitOutcome(
        id: String,
        metadata: CommitMetadata,
        outcome: CommitOutcome
    ) async throws -> Bool {
        try await store.acknowledgeCommitOutcome(
            id: id,
            metadata: metadata,
            outcome: outcome
        )
    }

    package func markTerminal(id: String) async throws {
        try await store.markTerminal(ids: [id], inserting: [])
    }

    package func markTerminal(task: DownloadTask) async throws {
        try await markTerminal(tasks: [task], ids: [task.id])
    }

    package func markTerminal(ids: Set<String>) async throws {
        try await store.markTerminal(ids: ids, inserting: [])
    }

    package func markTerminal(
        tasks: [DownloadTask],
        ids: Set<String>
    ) async throws {
        var records: [Record] = []
        records.reserveCapacity(tasks.count)
        for task in tasks where ids.contains(task.id) {
            records.append(
                Record(
                    id: task.id,
                    url: task.url,
                    destinationURL: task.destinationURL,
                    lifecycle: .terminal,
                    retryCount: await task.retryCount,
                    totalRetryCount: await task.totalRetryCount
                )
            )
        }
        try await store.markTerminal(ids: ids, inserting: records)
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
    private enum MutationDurability {
        case configured
        case crashCriticalCommit
    }

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
        let lifecycle: DownloadTaskPersistence.Record.Lifecycle?
        let retryCount: Int?
        let totalRetryCount: Int?
        let retryPlan: DownloadTaskPersistence.RetryPlan?
        let commitMetadata: DownloadTaskPersistence.CommitMetadata?
        let commitOutcome: DownloadTaskPersistence.CommitOutcome?

        init(
            sequence: Int64,
            timestamp: Date,
            kind: EventKind,
            taskID: String,
            url: URL?,
            destinationURL: URL?,
            resumeData: Data?,
            lifecycle: DownloadTaskPersistence.Record.Lifecycle?,
            retryCount: Int? = nil,
            totalRetryCount: Int? = nil,
            retryPlan: DownloadTaskPersistence.RetryPlan? = nil,
            commitMetadata: DownloadTaskPersistence.CommitMetadata? = nil,
            commitOutcome: DownloadTaskPersistence.CommitOutcome? = nil
        ) {
            self.sequence = sequence
            self.timestamp = timestamp
            self.kind = kind
            self.taskID = taskID
            self.url = url
            self.destinationURL = destinationURL
            self.resumeData = resumeData
            self.lifecycle = lifecycle
            self.retryCount = retryCount
            self.totalRetryCount = totalRetryCount
            self.retryPlan = retryPlan
            self.commitMetadata = commitMetadata
            self.commitOutcome = commitOutcome
        }
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
        let sessionStorageComponent = DownloadSessionStorageKey.component(for: sessionIdentifier)
        let directoryURL =
            persistenceRootURL
            .appendingPathComponent(sessionStorageComponent, isDirectory: true)
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
            // Terminal and committing rows are absorbing crash-recovery
            // markers. Generic upserts may refresh an active row, but can
            // never reopen a task whose completion path already claimed it.
            if let lifecycle = $0.records[id]?.lifecycle,
                lifecycle == .terminal || lifecycle == .committing
            {
                return []
            }
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
                resumeData: resumeData,
                lifecycle: .active,
                retryCount: $0.records[id]?.retryCount,
                totalRetryCount: $0.records[id]?.totalRetryCount
            )
            Self.appendIDToIndex(state: &$0, url: url, id: id)
            return [
                Event(
                    sequence: $0.nextSequence,
                    timestamp: .now,
                    kind: .upsert,
                    taskID: id,
                    url: url,
                    destinationURL: destinationURL,
                    resumeData: resumeData,
                    lifecycle: .active,
                    retryCount: $0.records[id]?.retryCount,
                    totalRetryCount: $0.records[id]?.totalRetryCount
                )
            ]
        }
    }

    package func beginStart(
        id: String,
        url: URL,
        destinationURL: URL,
        mode: DownloadTaskPersistence.StartMode,
        retryCount: Int,
        totalRetryCount: Int
    ) async throws -> Bool {
        let didBegin = OSAllocatedUnfairLock(initialState: false)
        try await mutate { state in
            let existing = state.records[id]
            let isAllowed: Bool
            switch mode {
            case .initial:
                isAllowed = existing == nil || existing?.lifecycle == .active
            case .automaticRetry:
                isAllowed = existing?.lifecycle == .retryPending
            case .manualRetry:
                isAllowed = existing == nil || existing?.lifecycle == .terminal
            }
            guard isAllowed else { return [] }

            if let existing, existing.url != url {
                Self.removeIDFromIndex(state: &state, url: existing.url, id: id)
            }
            let active = DownloadTaskPersistence.Record(
                id: id,
                url: url,
                destinationURL: destinationURL,
                lifecycle: .active,
                retryCount: retryCount,
                totalRetryCount: totalRetryCount
            )
            state.records[id] = active
            Self.appendIDToIndex(state: &state, url: url, id: id)
            didBegin.withLock { $0 = true }
            return [
                Event(
                    sequence: state.nextSequence,
                    timestamp: .now,
                    kind: .upsert,
                    taskID: id,
                    url: url,
                    destinationURL: destinationURL,
                    resumeData: nil,
                    lifecycle: .active,
                    retryCount: retryCount,
                    totalRetryCount: totalRetryCount
                )
            ]
        }
        return didBegin.withLock { $0 }
    }

    package func updateResumeData(
        id: String,
        resumeData: Data?,
        lifecycle: DownloadTaskPersistence.Record.Lifecycle
    ) async throws {
        try await mutate {
            guard lifecycle != .committing,
                let existing = $0.records[id],
                existing.lifecycle != .terminal,
                existing.lifecycle != .committing
            else { return [] }
            $0.records[id] = DownloadTaskPersistence.Record(
                id: existing.id,
                url: existing.url,
                destinationURL: existing.destinationURL,
                resumeData: resumeData,
                lifecycle: lifecycle,
                retryCount: existing.retryCount,
                totalRetryCount: existing.totalRetryCount,
                retryPlan: existing.retryPlan,
                commitMetadata: existing.commitMetadata,
                commitOutcome: existing.commitOutcome
            )
            return [
                Event(
                    sequence: $0.nextSequence,
                    timestamp: .now,
                    kind: .upsert,
                    taskID: existing.id,
                    url: existing.url,
                    destinationURL: existing.destinationURL,
                    resumeData: resumeData,
                    lifecycle: lifecycle,
                    retryCount: existing.retryCount,
                    totalRetryCount: existing.totalRetryCount,
                    retryPlan: existing.retryPlan,
                    commitMetadata: existing.commitMetadata,
                    commitOutcome: existing.commitOutcome
                )
            ]
        }
    }

    package func transitionResumeState(
        id: String,
        from expectedLifecycle: DownloadTaskPersistence.Record.Lifecycle?,
        to lifecycle: DownloadTaskPersistence.Record.Lifecycle,
        resumeData: Data?
    ) async throws -> Bool {
        let didTransition = OSAllocatedUnfairLock(initialState: false)
        try await mutate {
            guard lifecycle != .committing,
                let existing = $0.records[id],
                existing.lifecycle != .terminal,
                existing.lifecycle != .committing,
                existing.lifecycle == expectedLifecycle
            else { return [] }
            $0.records[id] = DownloadTaskPersistence.Record(
                id: existing.id,
                url: existing.url,
                destinationURL: existing.destinationURL,
                resumeData: resumeData,
                lifecycle: lifecycle,
                retryCount: existing.retryCount,
                totalRetryCount: existing.totalRetryCount,
                retryPlan: existing.retryPlan,
                commitMetadata: existing.commitMetadata,
                commitOutcome: existing.commitOutcome
            )
            didTransition.withLock { $0 = true }
            return [
                Event(
                    sequence: $0.nextSequence,
                    timestamp: .now,
                    kind: .upsert,
                    taskID: existing.id,
                    url: existing.url,
                    destinationURL: existing.destinationURL,
                    resumeData: resumeData,
                    lifecycle: lifecycle,
                    retryCount: existing.retryCount,
                    totalRetryCount: existing.totalRetryCount,
                    retryPlan: existing.retryPlan,
                    commitMetadata: existing.commitMetadata,
                    commitOutcome: existing.commitOutcome
                )
            ]
        }
        return didTransition.withLock { $0 }
    }

    package func updateRetryState(
        id: String,
        retryCount: Int,
        totalRetryCount: Int,
        retryPlan: DownloadTaskPersistence.RetryPlan?
    ) async throws -> Bool {
        let didUpdate = OSAllocatedUnfairLock(initialState: false)
        try await mutate {
            guard let existing = $0.records[id],
                existing.lifecycle == .active || existing.lifecycle == .retryPending
            else { return [] }
            $0.records[id] = DownloadTaskPersistence.Record(
                id: existing.id,
                url: existing.url,
                destinationURL: existing.destinationURL,
                resumeData: nil,
                lifecycle: .retryPending,
                retryCount: retryCount,
                totalRetryCount: totalRetryCount,
                retryPlan: retryPlan
            )
            didUpdate.withLock { $0 = true }
            return [
                Event(
                    sequence: $0.nextSequence,
                    timestamp: .now,
                    kind: .upsert,
                    taskID: existing.id,
                    url: existing.url,
                    destinationURL: existing.destinationURL,
                    resumeData: nil,
                    lifecycle: .retryPending,
                    retryCount: retryCount,
                    totalRetryCount: totalRetryCount,
                    retryPlan: retryPlan
                )
            ]
        }
        return didUpdate.withLock { $0 }
    }

    package func beginCommit(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata
    ) async throws -> Bool {
        let didBegin = OSAllocatedUnfairLock(initialState: false)
        try await mutate(durability: .crashCriticalCommit) { state in
            guard let existing = state.records[id] else { return [] }
            guard Self.isSHA256(metadata.stagingKey),
                Self.isSHA256(metadata.payloadSHA256),
                metadata.expectedByteCount >= 0,
                metadata.originalRequestURL == existing.url,
                metadata.destinationURL == existing.destinationURL
            else { return [] }
            let isAllowed =
                existing.lifecycle == nil
                || existing.lifecycle == .active
                || existing.lifecycle == .pausing
                || existing.lifecycle == .paused
                || existing.lifecycle == .resuming
            guard isAllowed else { return [] }

            let committing = DownloadTaskPersistence.Record(
                id: existing.id,
                url: existing.url,
                destinationURL: existing.destinationURL,
                lifecycle: .committing,
                retryCount: existing.retryCount,
                totalRetryCount: existing.totalRetryCount,
                commitMetadata: metadata
            )
            state.records[id] = committing
            didBegin.withLock { $0 = true }
            return [
                Event(
                    sequence: state.nextSequence,
                    timestamp: .now,
                    kind: .upsert,
                    taskID: committing.id,
                    url: committing.url,
                    destinationURL: committing.destinationURL,
                    resumeData: nil,
                    lifecycle: .committing,
                    retryCount: committing.retryCount,
                    totalRetryCount: committing.totalRetryCount,
                    commitMetadata: metadata
                )
            ]
        }
        return didBegin.withLock { $0 }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
            }
    }

    package func finishCommit(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata
    ) async throws -> Bool {
        try await transitionCommitToTerminal(
            id: id,
            metadata: metadata,
            outcome: .finished
        )
    }

    package func abandonCommit(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata?
    ) async throws -> Bool {
        try await transitionCommitToTerminal(
            id: id,
            metadata: metadata,
            outcome: .abandoned
        )
    }

    private func transitionCommitToTerminal(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata?,
        outcome: DownloadTaskPersistence.CommitOutcome
    ) async throws -> Bool {
        let didFinish = OSAllocatedUnfairLock(initialState: false)
        try await mutate(durability: .crashCriticalCommit) { state in
            guard let existing = state.records[id],
                existing.lifecycle == .committing,
                existing.commitMetadata == metadata
            else { return [] }

            let terminal = DownloadTaskPersistence.Record(
                id: existing.id,
                url: existing.url,
                destinationURL: existing.destinationURL,
                lifecycle: .terminal,
                retryCount: existing.retryCount,
                totalRetryCount: existing.totalRetryCount,
                commitMetadata: existing.commitMetadata,
                commitOutcome: outcome
            )
            state.records[id] = terminal
            didFinish.withLock { $0 = true }
            return [
                Event(
                    sequence: state.nextSequence,
                    timestamp: .now,
                    kind: .upsert,
                    taskID: terminal.id,
                    url: terminal.url,
                    destinationURL: terminal.destinationURL,
                    resumeData: nil,
                    lifecycle: .terminal,
                    retryCount: terminal.retryCount,
                    totalRetryCount: terminal.totalRetryCount,
                    commitMetadata: terminal.commitMetadata,
                    commitOutcome: outcome
                )
            ]
        }
        return didFinish.withLock { $0 }
    }

    package func acknowledgeCommitOutcome(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata,
        outcome: DownloadTaskPersistence.CommitOutcome
    ) async throws -> Bool {
        let didAcknowledge = OSAllocatedUnfairLock(initialState: false)
        try await mutate(durability: .crashCriticalCommit) { state in
            guard let existing = state.records[id],
                existing.lifecycle == .terminal,
                existing.commitMetadata == metadata,
                existing.commitOutcome == outcome
            else { return [] }

            state.records.removeValue(forKey: id)
            Self.removeIDFromIndex(state: &state, url: existing.url, id: id)
            state.tombstoneCount += 1
            didAcknowledge.withLock { $0 = true }
            return [
                Event(
                    sequence: state.nextSequence,
                    timestamp: .now,
                    kind: .remove,
                    taskID: id,
                    url: nil,
                    destinationURL: nil,
                    resumeData: nil,
                    lifecycle: nil
                )
            ]
        }
        return didAcknowledge.withLock { $0 }
    }

    package func markTerminal(
        ids: Set<String>,
        inserting records: [DownloadTaskPersistence.Record]
    ) async throws {
        guard !ids.isEmpty else { return }
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        try await mutate { state in
            var terminalRecords: [DownloadTaskPersistence.Record] = []
            terminalRecords.reserveCapacity(ids.count)
            for id in ids {
                if let lifecycle = state.records[id]?.lifecycle,
                    lifecycle == .terminal || lifecycle == .committing
                {
                    continue
                }
                guard let existing = state.records[id] ?? recordsByID[id] else { continue }
                guard existing.lifecycle != .committing else { continue }
                let terminal = DownloadTaskPersistence.Record(
                    id: existing.id,
                    url: existing.url,
                    destinationURL: existing.destinationURL,
                    resumeData: nil,
                    lifecycle: .terminal,
                    retryCount: existing.retryCount,
                    totalRetryCount: existing.totalRetryCount,
                    commitMetadata: existing.commitMetadata,
                    commitOutcome: existing.commitOutcome
                )
                state.records[id] = terminal
                Self.appendIDToIndex(state: &state, url: terminal.url, id: id)
                terminalRecords.append(terminal)
            }
            return terminalRecords.enumerated().map { index, record in
                Event(
                    sequence: state.nextSequence + Int64(index),
                    timestamp: .now,
                    kind: .upsert,
                    taskID: record.id,
                    url: record.url,
                    destinationURL: record.destinationURL,
                    resumeData: nil,
                    lifecycle: .terminal,
                    retryCount: record.retryCount,
                    totalRetryCount: record.totalRetryCount,
                    commitMetadata: record.commitMetadata,
                    commitOutcome: record.commitOutcome
                )
            }
        }
    }

    package func remove(id: String) async throws {
        // Presence must be checked against the state freshly loaded under the
        // directory lock. This actor's snapshot may predate a write from a
        // second store instance.
        try await mutate {
            guard let existing = $0.records[id], existing.lifecycle != .committing else { return [] }
            $0.records.removeValue(forKey: id)
            Self.removeIDFromIndex(state: &$0, url: existing.url, id: id)
            $0.tombstoneCount += 1
            return [
                Event(
                    sequence: $0.nextSequence,
                    timestamp: .now,
                    kind: .remove,
                    taskID: id,
                    url: nil,
                    destinationURL: nil,
                    resumeData: nil,
                    lifecycle: nil
                )
            ]
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
                if let existing = state.records[id], existing.lifecycle != .committing {
                    state.records.removeValue(forKey: id)
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
                    resumeData: nil,
                    lifecycle: nil
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
            let staleIDs = state.records.compactMap { id, record in
                !ids.contains(id) && record.lifecycle != .committing ? id : nil
            }
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
                    resumeData: nil,
                    lifecycle: nil
                )
            }
        }
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
    private func mutate(
        durability: MutationDurability = .configured,
        _ transform: (inout StoreState) -> [Event]
    ) async throws {
        let fsyncPolicy = self.fsyncPolicy
        let compactionPolicy = self.compactionPolicy
        let fsync = self.fsync
        let effectiveFsyncPolicy: DownloadConfiguration.PersistenceFsyncPolicy =
            switch durability {
            case .configured:
                fsyncPolicy
            case .crashCriticalCommit:
                .always
            }
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
            fsyncPolicy: effectiveFsyncPolicy,
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
                fsyncPolicy: effectiveFsyncPolicy,
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
