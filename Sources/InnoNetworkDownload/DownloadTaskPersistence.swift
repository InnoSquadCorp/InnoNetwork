import Foundation
import InnoNetwork

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
        checkpointDataReader: @escaping @Sendable (Int32) throws -> Data = {
            try AppendLogDownloadTaskStore.readAll(from: $0)
        },
        logFileHandleFactory: @escaping @Sendable (Int32) throws -> FileHandle = {
            FileHandle(fileDescriptor: $0, closeOnDealloc: true)
        },
        fileOperations: AppendLogDownloadTaskStore.FileOperations = .live,
        fsync: @escaping @Sendable (Int32) -> Int32 = Darwin.fsync
    ) throws {
        self.store = try AppendLogDownloadTaskStore(
            sessionIdentifier: sessionIdentifier,
            fileManager: fileManager,
            baseDirectoryURL: baseDirectoryURL,
            fsyncPolicy: fsyncPolicy,
            compactionPolicy: compactionPolicy,
            checkpointDataReader: checkpointDataReader,
            logFileHandleFactory: logFileHandleFactory,
            fileOperations: fileOperations,
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
