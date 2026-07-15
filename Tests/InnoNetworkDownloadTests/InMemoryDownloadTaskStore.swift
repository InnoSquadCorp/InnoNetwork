import Foundation

@testable import InnoNetworkDownload

/// In-memory `DownloadTaskStore` used by the Download test suites so the
/// stub harness does not touch disk via `AppendLogDownloadTaskStore`.
/// Shared by `StubDownloadHarness`, `DownloadRetryTimingTests`, and the
/// restore-path tests that need to pre-populate persistence before the
/// manager starts its restore coordinator.
///
/// Internal (not `private`) so tests can construct a store, seed records,
/// and hand it to the harness / manager without ad-hoc duplicates.
actor InMemoryDownloadTaskStore: DownloadTaskStore {
    private var records: [String: DownloadTaskPersistence.Record] = [:]
    private var shouldFailRemove = false
    private var shouldFailUpsert = false
    private var suspendsUpserts = false
    private var pendingUpsertWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspendsTerminalWrites = false
    private var pendingTerminalWriteWaiters: [CheckedContinuation<Void, Never>] = []
    /// Number of times the bulk `remove(ids:)` entry point has been invoked.
    /// Surface so tests can assert that `cancelAll` reaches persistence
    /// through the bulk path exactly once instead of looping `remove(id:)`.
    private(set) var bulkRemoveCallCount = 0
    /// Number of times the per-id `remove(id:)` entry point has been invoked.
    private(set) var singleRemoveCallCount = 0

    init(
        seed: [DownloadTaskPersistence.Record] = [],
        shouldFailRemove: Bool = false
    ) {
        self.shouldFailRemove = shouldFailRemove
        for record in seed {
            records[record.id] = record
        }
    }

    func setRemoveFailure(_ shouldFail: Bool) {
        shouldFailRemove = shouldFail
    }

    func setUpsertFailure(_ shouldFail: Bool) {
        shouldFailUpsert = shouldFail
    }

    func suspendUpserts() {
        suspendsUpserts = true
    }

    func resumeUpserts() {
        suspendsUpserts = false
        let waiters = pendingUpsertWaiters
        pendingUpsertWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    var pendingUpsertCount: Int {
        pendingUpsertWaiters.count
    }

    func suspendTerminalWrites() {
        suspendsTerminalWrites = true
    }

    func resumeTerminalWrites() {
        suspendsTerminalWrites = false
        let waiters = pendingTerminalWriteWaiters
        pendingTerminalWriteWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    var pendingTerminalWriteCount: Int {
        pendingTerminalWriteWaiters.count
    }

    func upsert(id: String, url: URL, destinationURL: URL, resumeData: Data?) async throws {
        if suspendsUpserts {
            await withCheckedContinuation { continuation in
                pendingUpsertWaiters.append(continuation)
            }
        }
        if shouldFailUpsert {
            throw InMemoryDownloadTaskStoreError.upsertFailed(id)
        }
        if let lifecycle = records[id]?.lifecycle,
            lifecycle == .terminal || lifecycle == .committing
        {
            return
        }
        let existing = records[id]
        records[id] = DownloadTaskPersistence.Record(
            id: id,
            url: url,
            destinationURL: destinationURL,
            resumeData: resumeData,
            lifecycle: .active,
            retryCount: existing?.retryCount,
            totalRetryCount: existing?.totalRetryCount
        )
    }

    func beginStart(
        id: String,
        url: URL,
        destinationURL: URL,
        mode: DownloadTaskPersistence.StartMode,
        retryCount: Int,
        totalRetryCount: Int
    ) async throws -> Bool {
        if suspendsUpserts {
            await withCheckedContinuation { continuation in
                pendingUpsertWaiters.append(continuation)
            }
        }
        if shouldFailUpsert {
            throw InMemoryDownloadTaskStoreError.upsertFailed(id)
        }
        let existing = records[id]
        let isAllowed: Bool
        switch mode {
        case .initial:
            isAllowed = existing == nil || existing?.lifecycle == .active
        case .automaticRetry:
            isAllowed = existing?.lifecycle == .retryPending
        case .manualRetry:
            isAllowed = existing == nil || existing?.lifecycle == .terminal
        }
        guard isAllowed else { return false }
        records[id] = DownloadTaskPersistence.Record(
            id: id,
            url: url,
            destinationURL: destinationURL,
            lifecycle: .active,
            retryCount: retryCount,
            totalRetryCount: totalRetryCount
        )
        return true
    }

    func updateResumeData(
        id: String,
        resumeData: Data?,
        lifecycle: DownloadTaskPersistence.Record.Lifecycle
    ) async throws {
        if suspendsUpserts {
            await withCheckedContinuation { continuation in
                pendingUpsertWaiters.append(continuation)
            }
        }
        if shouldFailUpsert {
            throw InMemoryDownloadTaskStoreError.upsertFailed(id)
        }
        guard lifecycle != .committing,
            let record = records[id],
            record.lifecycle != .terminal,
            record.lifecycle != .committing
        else { return }
        records[id] = DownloadTaskPersistence.Record(
            id: id,
            url: record.url,
            destinationURL: record.destinationURL,
            resumeData: resumeData,
            lifecycle: lifecycle,
            retryCount: record.retryCount,
            totalRetryCount: record.totalRetryCount,
            retryPlan: record.retryPlan,
            commitMetadata: record.commitMetadata,
            commitOutcome: record.commitOutcome
        )
    }

    func transitionResumeState(
        id: String,
        from expectedLifecycle: DownloadTaskPersistence.Record.Lifecycle?,
        to lifecycle: DownloadTaskPersistence.Record.Lifecycle,
        resumeData: Data?
    ) async throws -> Bool {
        if suspendsUpserts {
            await withCheckedContinuation { continuation in
                pendingUpsertWaiters.append(continuation)
            }
        }
        if shouldFailUpsert {
            throw InMemoryDownloadTaskStoreError.upsertFailed(id)
        }
        guard lifecycle != .committing,
            let record = records[id],
            record.lifecycle != .terminal,
            record.lifecycle != .committing,
            record.lifecycle == expectedLifecycle
        else { return false }
        records[id] = DownloadTaskPersistence.Record(
            id: id,
            url: record.url,
            destinationURL: record.destinationURL,
            resumeData: resumeData,
            lifecycle: lifecycle,
            retryCount: record.retryCount,
            totalRetryCount: record.totalRetryCount,
            retryPlan: record.retryPlan,
            commitMetadata: record.commitMetadata,
            commitOutcome: record.commitOutcome
        )
        return true
    }

    func updateRetryState(
        id: String,
        retryCount: Int,
        totalRetryCount: Int,
        retryPlan: DownloadTaskPersistence.RetryPlan?
    ) async throws -> Bool {
        if suspendsUpserts {
            await withCheckedContinuation { continuation in
                pendingUpsertWaiters.append(continuation)
            }
        }
        if shouldFailUpsert {
            throw InMemoryDownloadTaskStoreError.upsertFailed(id)
        }
        guard let record = records[id],
            record.lifecycle == .active || record.lifecycle == .retryPending
        else { return false }
        records[id] = DownloadTaskPersistence.Record(
            id: id,
            url: record.url,
            destinationURL: record.destinationURL,
            resumeData: nil,
            lifecycle: .retryPending,
            retryCount: retryCount,
            totalRetryCount: totalRetryCount,
            retryPlan: retryPlan
        )
        return true
    }

    func beginCommit(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata
    ) async throws -> Bool {
        if suspendsUpserts {
            await withCheckedContinuation { continuation in
                pendingUpsertWaiters.append(continuation)
            }
        }
        if shouldFailUpsert {
            throw InMemoryDownloadTaskStoreError.upsertFailed(id)
        }
        guard let record = records[id] else { return false }
        guard !metadata.stagingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            metadata.expectedByteCount >= 0,
            metadata.originalRequestURL == record.url
        else { return false }
        let isAllowed =
            record.lifecycle == nil
            || record.lifecycle == .active
            || record.lifecycle == .pausing
            || record.lifecycle == .paused
            || record.lifecycle == .resuming
        guard isAllowed else { return false }
        records[id] = DownloadTaskPersistence.Record(
            id: record.id,
            url: record.url,
            destinationURL: record.destinationURL,
            lifecycle: .committing,
            retryCount: record.retryCount,
            totalRetryCount: record.totalRetryCount,
            commitMetadata: metadata
        )
        return true
    }

    func finishCommit(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata
    ) async throws -> Bool {
        try await transitionCommitToTerminal(
            id: id,
            metadata: metadata,
            outcome: .finished
        )
    }

    func abandonCommit(
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
        if suspendsTerminalWrites {
            await withCheckedContinuation { continuation in
                pendingTerminalWriteWaiters.append(continuation)
            }
        }
        if shouldFailUpsert {
            throw InMemoryDownloadTaskStoreError.upsertFailed(id)
        }
        guard let record = records[id],
            record.lifecycle == .committing,
            record.commitMetadata == metadata
        else { return false }
        records[id] = DownloadTaskPersistence.Record(
            id: record.id,
            url: record.url,
            destinationURL: record.destinationURL,
            lifecycle: .terminal,
            retryCount: record.retryCount,
            totalRetryCount: record.totalRetryCount,
            commitMetadata: record.commitMetadata,
            commitOutcome: outcome
        )
        return true
    }

    func acknowledgeCommitOutcome(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata,
        outcome: DownloadTaskPersistence.CommitOutcome
    ) async throws -> Bool {
        singleRemoveCallCount += 1
        if shouldFailRemove {
            throw InMemoryDownloadTaskStoreError.removeFailed(id)
        }
        guard let record = records[id],
            record.lifecycle == .terminal,
            record.commitMetadata == metadata,
            record.commitOutcome == outcome
        else { return false }
        records.removeValue(forKey: id)
        return true
    }

    func markTerminal(
        ids: Set<String>,
        inserting insertedRecords: [DownloadTaskPersistence.Record]
    ) async throws {
        if suspendsTerminalWrites {
            await withCheckedContinuation { continuation in
                pendingTerminalWriteWaiters.append(continuation)
            }
        }
        if shouldFailUpsert {
            throw InMemoryDownloadTaskStoreError.upsertFailed(ids.sorted().joined(separator: ","))
        }
        let insertedByID = Dictionary(uniqueKeysWithValues: insertedRecords.map { ($0.id, $0) })
        for id in ids {
            if let lifecycle = records[id]?.lifecycle,
                lifecycle == .terminal || lifecycle == .committing
            {
                continue
            }
            guard let record = records[id] ?? insertedByID[id] else { continue }
            guard record.lifecycle != .committing else { continue }
            records[id] = DownloadTaskPersistence.Record(
                id: id,
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

    func remove(id: String) async throws {
        singleRemoveCallCount += 1
        if shouldFailRemove {
            throw InMemoryDownloadTaskStoreError.removeFailed(id)
        }
        guard records[id]?.lifecycle != .committing else { return }
        records.removeValue(forKey: id)
    }

    func remove(ids: Set<String>) async throws {
        bulkRemoveCallCount += 1
        if shouldFailRemove {
            throw InMemoryDownloadTaskStoreError.bulkRemoveFailed(ids)
        }
        for id in ids {
            if records[id]?.lifecycle != .committing {
                records.removeValue(forKey: id)
            }
        }
    }

    func record(forID id: String) async -> DownloadTaskPersistence.Record? {
        records[id]
    }

    func allRecords() async -> [DownloadTaskPersistence.Record] {
        Array(records.values)
    }

    func id(forURL url: URL?) async -> String? {
        guard let url else { return nil }
        return records.values.first(where: { $0.url == url })?.id
    }

    func prune(keeping ids: Set<String>) async throws {
        records = records.filter { id, record in
            ids.contains(id) || record.lifecycle == .committing
        }
    }
}


enum InMemoryDownloadTaskStoreError: Error, Equatable {
    case removeFailed(String)
    case bulkRemoveFailed(Set<String>)
    case upsertFailed(String)
}
