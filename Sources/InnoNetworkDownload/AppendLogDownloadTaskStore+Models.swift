import Foundation

extension AppendLogDownloadTaskStore {
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
}
