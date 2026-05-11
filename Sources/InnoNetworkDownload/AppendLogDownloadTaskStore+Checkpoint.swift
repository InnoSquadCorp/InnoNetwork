import Foundation

// Split out of `DownloadTaskPersistence.swift` so the checkpoint loader,
// writer, and URL-index rebuild — the operations that bridge persisted
// `Envelope` payloads with in-memory `StoreState` — live together. All
// helpers stay `static`; this file only relocates code, no behaviour
// changes.
extension AppendLogDownloadTaskStore {

    static func loadState(
        directoryURL: URL,
        checkpointURL: URL,
        logURL: URL,
        fileManager: FileManager
    ) throws -> StoreState {
        try ensureDirectoryExists(at: directoryURL, fileManager: fileManager)
        var records: [String: DownloadTaskPersistence.Record] = [:]
        var urlToID: [URL: [String]] = [:]
        var nextSequence: Int64 = 0
        var logEventCount = 0
        var tombstoneCount = 0

        if fileManager.fileExists(atPath: checkpointURL.path()) {
            do {
                let data = try Data(contentsOf: checkpointURL)
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard envelope.version == 1 else {
                    throw CocoaError(.coderInvalidValue)
                }
                records = envelope.records
                urlToID = rebuildURLIndex(
                    records: records,
                    orderedRecordIDs: envelope.orderedRecordIDs
                )
            } catch {
                quarantineFileIfNeeded(checkpointURL, fileManager: fileManager)
                records = [:]
                urlToID = [:]
            }
        }

        if fileManager.fileExists(atPath: logURL.path()) {
            let replayResult = try replayLog(
                at: logURL,
                onto: records,
                initialURLToID: urlToID,
                checkpointURL: checkpointURL,
                fileManager: fileManager
            )
            records = replayResult.records
            urlToID = replayResult.urlToID
            nextSequence = replayResult.nextSequence
            logEventCount = replayResult.logEventCount
            tombstoneCount = replayResult.tombstoneCount
        }

        return StoreState(
            records: records,
            urlToID: urlToID,
            nextSequence: nextSequence,
            logEventCount: logEventCount,
            tombstoneCount: tombstoneCount,
            logSize: fileSize(at: logURL, fileManager: fileManager)
        )
    }

    static func writeCheckpoint(
        records: [String: DownloadTaskPersistence.Record],
        urlToID: [URL: [String]],
        to checkpointURL: URL,
        fileManager: FileManager,
        fsyncPolicy: DownloadConfiguration.PersistenceFsyncPolicy,
        fsync: @escaping @Sendable (Int32) -> Int32
    ) throws {
        let envelope = Envelope(
            records: records,
            orderedRecordIDs: checkpointRecordOrder(records: records, urlToID: urlToID)
        )
        let data = try JSONEncoder().encode(envelope)
        try writeAtomically(
            data: data,
            to: checkpointURL,
            fileManager: fileManager,
            fsyncBeforeRename: fsyncPolicy != .never,
            fsync: fsync
        )
    }

    static func checkpointRecordOrder(
        records: [String: DownloadTaskPersistence.Record],
        urlToID: [URL: [String]]
    ) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []

        let orderedURLs = urlToID.keys.sorted { lhs, rhs in
            lhs.absoluteString < rhs.absoluteString
        }
        for url in orderedURLs {
            // Checkpoints store same-URL ids latest-first so legacy readers
            // can recover the newest task without replaying append-log order.
            let ids = (urlToID[url] ?? []).reversed()
            for id in ids where records[id] != nil && seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        for id in records.keys.sorted() where seen.insert(id).inserted {
            ordered.append(id)
        }
        return ordered
    }

    static func rebuildURLIndex(
        records: [String: DownloadTaskPersistence.Record],
        orderedRecordIDs: [String]?
    ) -> [URL: [String]] {
        var state = StoreState(
            records: records,
            urlToID: [:],
            nextSequence: 0,
            logEventCount: 0,
            tombstoneCount: 0,
            logSize: 0
        )
        var seen: Set<String> = []

        // The in-memory reverse index is oldest-first with `last` as winner,
        // so replay latest-first checkpoint order in reverse.
        for id in (orderedRecordIDs ?? []).reversed() {
            guard let record = records[id], seen.insert(id).inserted else { continue }
            appendIDToIndex(state: &state, url: record.url, id: id)
        }
        for id in records.keys.sorted() where seen.insert(id).inserted {
            guard let record = records[id] else { continue }
            appendIDToIndex(state: &state, url: record.url, id: id)
        }
        return state.urlToID
    }
}
