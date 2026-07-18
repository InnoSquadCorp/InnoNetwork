import Darwin
import Foundation
import os

package actor AppendLogDownloadTaskStore: DownloadTaskStore {
    private enum MutationDurability {
        case configured
        case crashCriticalCommit
    }
    private let directoryDescriptor: Int32
    private let fsyncPolicy: DownloadConfiguration.PersistenceFsyncPolicy
    private let compactionPolicy: DownloadConfiguration.PersistenceCompactionPolicy
    private let checkpointDataReader: @Sendable (Int32) throws -> Data
    private let logFileHandleFactory: @Sendable (Int32) throws -> FileHandle
    private let fileOperations: FileOperations
    private let fsync: @Sendable (Int32) -> Int32
    private var state: StoreState

    package init(
        sessionIdentifier: String,
        fileManager: sending FileManager = .default,
        baseDirectoryURL: URL? = nil,
        fsyncPolicy: DownloadConfiguration.PersistenceFsyncPolicy = .onCheckpoint,
        compactionPolicy: DownloadConfiguration.PersistenceCompactionPolicy = .default,
        checkpointDataReader: @escaping @Sendable (Int32) throws -> Data = {
            try AppendLogDownloadTaskStore.readAll(from: $0)
        },
        logFileHandleFactory: @escaping @Sendable (Int32) throws -> FileHandle = {
            FileHandle(fileDescriptor: $0, closeOnDealloc: true)
        },
        fileOperations: FileOperations = .live,
        fsync: @escaping @Sendable (Int32) -> Int32 = Darwin.fsync
    ) throws {
        let baseDirectory = baseDirectoryURL ?? Self.defaultBaseDirectory(fileManager: fileManager)
        let sessionStorageComponent = DownloadSessionStorageKey.component(for: sessionIdentifier)
        let anchoredDirectory = try Self.openAnchoredSessionDirectory(
            baseDirectoryURL: baseDirectory,
            sessionStorageComponent: sessionStorageComponent,
            fileManager: fileManager,
            operations: fileOperations
        )
        let initialState: StoreState
        do {
            let lockDescriptor = try Self.acquireDirectoryLockBlocking(
                directoryDescriptor: anchoredDirectory.descriptor,
                timeout: 10
            )
            defer { Self.releaseDirectoryLock(lockDescriptor) }
            initialState = try Self.loadState(
                directoryDescriptor: anchoredDirectory.descriptor,
                checkpointDataReader: checkpointDataReader,
                logFileHandleFactory: logFileHandleFactory,
                operations: fileOperations,
                fsync: fsync
            )
        } catch {
            close(anchoredDirectory.descriptor)
            throw error
        }

        // Resource attributes can be stripped by restores or external file
        // management. Reapply them whenever the store reopens, including when
        // no mutation follows this initialization.
        for name in [Self.checkpointName, Self.logName, Self.lockName] {
            guard
                let descriptor = try? Self.openRegularFile(
                    directoryDescriptor: anchoredDirectory.descriptor,
                    name: name,
                    flags: O_RDONLY
                ).descriptor
            else { continue }
            defer { close(descriptor) }
            DownloadOwnedStorageProtection.apply(toFileDescriptor: descriptor)
        }

        self.directoryDescriptor = anchoredDirectory.descriptor
        self.fsyncPolicy = fsyncPolicy
        self.compactionPolicy = compactionPolicy
        self.checkpointDataReader = checkpointDataReader
        self.logFileHandleFactory = logFileHandleFactory
        self.fileOperations = fileOperations
        self.fsync = fsync
        self.state = initialState
    }

    deinit {
        close(directoryDescriptor)
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
        let checkpointDataReader = self.checkpointDataReader
        let logFileHandleFactory = self.logFileHandleFactory
        let fileOperations = self.fileOperations
        let fsync = self.fsync
        let effectiveFsyncPolicy: DownloadConfiguration.PersistenceFsyncPolicy =
            switch durability {
            case .configured:
                fsyncPolicy
            case .crashCriticalCommit:
                .always
            }
        let descriptorRaw = try Self.openLockDescriptor(
            directoryDescriptor: directoryDescriptor
        )
        let descriptor = try await Self.awaitDirectoryLock(descriptor: descriptorRaw, timeout: 10)
        defer { Self.releaseDirectoryLock(descriptor) }
        var diskState = try Self.loadState(
            directoryDescriptor: directoryDescriptor,
            checkpointDataReader: checkpointDataReader,
            logFileHandleFactory: logFileHandleFactory,
            operations: fileOperations,
            fsync: fsync
        )

        let events = transform(&diskState)
        guard !events.isEmpty else {
            state = diskState
            return
        }

        try Self.append(
            events: events,
            directoryDescriptor: directoryDescriptor,
            fsyncPolicy: effectiveFsyncPolicy,
            fsync: fsync
        )
        diskState.logEventCount += events.count
        diskState.logSize = try Self.fileSize(
            directoryDescriptor: directoryDescriptor,
            name: Self.logName
        )
        diskState.nextSequence += Int64(events.count)

        if Self.shouldCompact(state: diskState, policy: compactionPolicy) {
            try Self.writeCheckpoint(
                records: diskState.records,
                urlToID: diskState.urlToID,
                directoryDescriptor: directoryDescriptor,
                operations: fileOperations,
                fsyncPolicy: effectiveFsyncPolicy,
                fsync: fsync
            )
            try Self.resetLog(
                directoryDescriptor: directoryDescriptor,
                operations: fileOperations
            )
            diskState.logEventCount = 0
            diskState.tombstoneCount = 0
            diskState.logSize = 0
        }

        state = diskState
    }

}
