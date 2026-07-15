import Darwin
import Foundation

// Split out of `DownloadTaskPersistence.swift` so the append-log writer,
// log-replay parser (with corrupt-suffix recovery), and compaction trigger
// live next to each other. All helpers stay `static` at the type level;
// this file only relocates code, no behaviour changes.
extension AppendLogDownloadTaskStore {

    static func replayLog(
        at logURL: URL,
        onto initialRecords: [String: DownloadTaskPersistence.Record],
        initialURLToID: [URL: [String]],
        checkpointURL: URL,
        fileManager: FileManager
    ) throws -> (
        records: [String: DownloadTaskPersistence.Record],
        urlToID: [URL: [String]],
        nextSequence: Int64,
        logEventCount: Int,
        tombstoneCount: Int
    ) {
        var records = initialRecords
        var urlToID = initialURLToID
        var nextSequence: Int64 = 0
        var logEventCount = 0
        var tombstoneCount = 0

        let handle = try FileHandle(forReadingFrom: logURL)
        defer { try? handle.close() }

        var buffer = Data()
        var didReadAnyBytes = false
        var didEncounterCorruptSuffix = false
        let chunkSize = 64 * 1024
        let maximumReplayLineBytes = 64 * 1024 * 1024
        let decoder = JSONDecoder()

        func replayLine(_ lineData: Data) throws {
            guard !lineData.isEmpty else { return }
            let event = try decoder.decode(Event.self, from: lineData)
            switch event.kind {
            case .upsert:
                guard let url = event.url, let destinationURL = event.destinationURL else { return }
                if let existing = records[event.taskID], existing.url != url {
                    var ids = urlToID[existing.url] ?? []
                    ids.removeAll { $0 == event.taskID }
                    if ids.isEmpty {
                        urlToID.removeValue(forKey: existing.url)
                    } else {
                        urlToID[existing.url] = ids
                    }
                }
                records[event.taskID] = DownloadTaskPersistence.Record(
                    id: event.taskID,
                    url: url,
                    destinationURL: destinationURL,
                    resumeData: event.resumeData,
                    lifecycle: event.lifecycle,
                    retryCount: event.retryCount,
                    totalRetryCount: event.totalRetryCount,
                    retryPlan: event.retryPlan,
                    commitMetadata: event.commitMetadata,
                    commitOutcome: event.commitOutcome
                )
                var ids = urlToID[url] ?? []
                ids.removeAll { $0 == event.taskID }
                ids.append(event.taskID)
                urlToID[url] = ids
            case .remove:
                if let existing = records.removeValue(forKey: event.taskID) {
                    var ids = urlToID[existing.url] ?? []
                    ids.removeAll { $0 == event.taskID }
                    if ids.isEmpty {
                        urlToID.removeValue(forKey: existing.url)
                    } else {
                        urlToID[existing.url] = ids
                    }
                }
                tombstoneCount += 1
            }
            nextSequence = max(nextSequence, event.sequence + 1)
            logEventCount += 1
        }

        func processBufferedLine(upTo newlineIndex: Data.Index) throws {
            var lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            if lineData.last == 0x0D {
                lineData.removeLast()
            }
            let nextIndex = buffer.index(after: newlineIndex)
            buffer.removeSubrange(buffer.startIndex..<nextIndex)
            try replayLine(lineData)
        }

        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            didReadAnyBytes = true
            buffer.append(chunk)

            if buffer.count > maximumReplayLineBytes, buffer.firstIndex(of: 0x0A) == nil {
                didEncounterCorruptSuffix = true
                break
            }

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                do {
                    try processBufferedLine(upTo: newlineIndex)
                } catch {
                    didEncounterCorruptSuffix = true
                    break
                }
            }

            if didEncounterCorruptSuffix {
                break
            }
        }

        if !didReadAnyBytes {
            return (records, urlToID, nextSequence, logEventCount, tombstoneCount)
        }

        if !didEncounterCorruptSuffix, !buffer.isEmpty {
            if buffer.last == 0x0D {
                buffer.removeLast()
            }
            do {
                try replayLine(buffer)
            } catch {
                didEncounterCorruptSuffix = true
            }
        }

        if didEncounterCorruptSuffix {
            // Recovery path: a partial / corrupt suffix of the log forced us
            // to rewrite the checkpoint. fsync defensively so the recovery
            // does not have to be redone if the process crashes again before
            // the OS flushes.
            quarantineFileIfNeeded(logURL, fileManager: fileManager)
            try writeCheckpoint(
                records: records,
                urlToID: urlToID,
                to: checkpointURL,
                fileManager: fileManager,
                fsyncPolicy: .onCheckpoint,
                fsync: Darwin.fsync
            )
            try resetLog(at: logURL, fileManager: fileManager)
        }

        return (records, urlToID, nextSequence, logEventCount, tombstoneCount)
    }

    static func append(
        events: [Event],
        to logURL: URL,
        fileManager: FileManager,
        fsyncPolicy: DownloadConfiguration.PersistenceFsyncPolicy,
        fsync: @Sendable (Int32) -> Int32
    ) throws {
        let logWasCreated = !fileManager.fileExists(atPath: logURL.path())
        if logWasCreated {
            try Data().write(to: logURL)
            DownloadOwnedStorageProtection.apply(to: logURL, fileManager: fileManager)
        }

        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()

        let encoder = JSONEncoder()
        for event in events {
            let data = try encoder.encode(event)
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
        }

        // .always policy forces buffered writes through to stable storage
        // after each append-log mutation batch. .onCheckpoint and .never skip
        // the cost — the next checkpoint or the OS flush is responsible for
        // durability.
        if fsyncPolicy == .always {
            try fsyncFileDescriptor(handle.fileDescriptor, fsync: fsync)
            // The append is not crash-durable if the log's directory entry can
            // still be lost. Sync the parent even for an existing path because
            // a prior `.never` mutation may have created or replaced the log
            // without establishing that directory durability.
            try fsyncParentDirectory(of: logURL, fsync: fsync)
        }
    }

    static func shouldCompact(
        state: StoreState,
        policy: DownloadConfiguration.PersistenceCompactionPolicy
    ) -> Bool {
        if state.logEventCount >= policy.maxEvents {
            return true
        }

        if state.logSize >= policy.maxLogBytes {
            return true
        }

        guard state.logEventCount > 0 else { return false }
        let tombstoneRatio = Double(state.tombstoneCount) / Double(state.logEventCount)
        return tombstoneRatio >= policy.tombstoneRatio
    }
}
