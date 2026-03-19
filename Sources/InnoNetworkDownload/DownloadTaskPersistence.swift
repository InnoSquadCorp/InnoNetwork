import Darwin
import Foundation


package protocol DownloadTaskStore: Actor {
    func upsert(id: String, url: URL, destinationURL: URL) async
    func remove(id: String) async
    func record(forID id: String) async -> DownloadTaskPersistence.Record?
    func allRecords() async -> [DownloadTaskPersistence.Record]
    func id(forURL url: URL?) async -> String?
    func prune(keeping ids: Set<String>) async
}

package actor DownloadTaskPersistence {
    package struct Record: Codable, Sendable {
        let id: String
        let url: URL
        let destinationURL: URL
    }

    private let store: any DownloadTaskStore

    package init(
        sessionIdentifier: String,
        fileManager: FileManager = .default,
        baseDirectoryURL: URL? = nil
    ) {
        _ = fileManager
        self.store = AppendLogDownloadTaskStore(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )
    }

    package init(store: any DownloadTaskStore) {
        self.store = store
    }

    package func upsert(id: String, url: URL, destinationURL: URL) async {
        await store.upsert(id: id, url: url, destinationURL: destinationURL)
    }

    package func remove(id: String) async {
        await store.remove(id: id)
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

    package func prune(keeping ids: Set<String>) async {
        await store.prune(keeping: ids)
    }
}

package actor AppendLogDownloadTaskStore: DownloadTaskStore {
    private struct Envelope: Codable, Sendable {
        let version: Int
        let records: [String: DownloadTaskPersistence.Record]
    }

    private enum EventKind: String, Codable, Sendable {
        case upsert
        case remove
    }

    private struct Event: Codable, Sendable {
        let sequence: Int64
        let timestamp: Date
        let kind: EventKind
        let taskID: String
        let url: URL?
        let destinationURL: URL?
    }

    private struct StoreState: Sendable {
        var records: [String: DownloadTaskPersistence.Record]
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
    private var state: StoreState

    package init(
        sessionIdentifier: String,
        baseDirectoryURL: URL? = nil
    ) {
        let fileManager = FileManager.default
        let baseDirectory = baseDirectoryURL ?? Self.defaultBaseDirectory(fileManager: fileManager)
        let directoryURL = baseDirectory
            .appendingPathComponent("InnoNetworkDownload", isDirectory: true)
            .appendingPathComponent(sessionIdentifier, isDirectory: true)
        let checkpointURL = directoryURL.appendingPathComponent("checkpoint.json", isDirectory: false)
        let logURL = directoryURL.appendingPathComponent("events.log", isDirectory: false)
        let lockURL = directoryURL.appendingPathComponent(".lock", isDirectory: false)
        let initialState: StoreState

        do {
            try Self.ensureDirectoryExists(at: directoryURL, fileManager: fileManager)
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
            initialState = StoreState(records: [:], nextSequence: 0, logEventCount: 0, tombstoneCount: 0, logSize: 0)
        }

        self.fileManager = fileManager
        self.directoryURL = directoryURL
        self.checkpointURL = checkpointURL
        self.logURL = logURL
        self.lockURL = lockURL
        self.state = initialState
    }

    package func upsert(id: String, url: URL, destinationURL: URL) async {
        await mutate {
            $0.records[id] = DownloadTaskPersistence.Record(id: id, url: url, destinationURL: destinationURL)
            return Event(
                sequence: $0.nextSequence,
                timestamp: .now,
                kind: .upsert,
                taskID: id,
                url: url,
                destinationURL: destinationURL
            )
        }
    }

    package func remove(id: String) async {
        guard state.records[id] != nil else { return }
        await mutate {
            $0.records.removeValue(forKey: id)
            $0.tombstoneCount += 1
            return Event(
                sequence: $0.nextSequence,
                timestamp: .now,
                kind: .remove,
                taskID: id,
                url: nil,
                destinationURL: nil
            )
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
        return state.records.first(where: { $0.value.url == url })?.key
    }

    package func prune(keeping ids: Set<String>) async {
        let staleIDs = state.records.keys.filter { !ids.contains($0) }
        guard !staleIDs.isEmpty else { return }

        await mutate { state in
            for staleID in staleIDs {
                state.records.removeValue(forKey: staleID)
            }
            state.tombstoneCount += staleIDs.count
            return staleIDs.enumerated().map { index, staleID in
                Event(
                    sequence: state.nextSequence + Int64(index),
                    timestamp: .now,
                    kind: .remove,
                    taskID: staleID,
                    url: nil,
                    destinationURL: nil
                )
            }
        }
    }

    private func mutate(_ transform: (inout StoreState) -> Event) async {
        await mutate { state in [transform(&state)] }
    }

    private func mutate(_ transform: (inout StoreState) -> [Event]) async {
        do {
            let updatedState = try Self.withDirectoryLock(lockURL: lockURL, fileManager: fileManager) {
                var diskState = try Self.loadState(
                    directoryURL: directoryURL,
                    checkpointURL: checkpointURL,
                    logURL: logURL,
                    fileManager: fileManager
                )

                let events = transform(&diskState)
                guard !events.isEmpty else { return diskState }

                try Self.append(events: events, to: logURL, fileManager: fileManager)
                diskState.logEventCount += events.count
                diskState.logSize = Self.fileSize(at: logURL, fileManager: fileManager)
                diskState.nextSequence += Int64(events.count)

                if Self.shouldCompact(state: diskState) {
                    try Self.writeCheckpoint(records: diskState.records, to: checkpointURL, fileManager: fileManager)
                    try Self.resetLog(at: logURL, fileManager: fileManager)
                    diskState.logEventCount = 0
                    diskState.tombstoneCount = 0
                    diskState.logSize = 0
                }

                return diskState
            }
            state = updatedState
        } catch {
            // Keep the last durable state authoritative for the process.
        }
    }

    private static func defaultBaseDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static func ensureDirectoryExists(at directoryURL: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private static func loadState(
        directoryURL: URL,
        checkpointURL: URL,
        logURL: URL,
        fileManager: FileManager
    ) throws -> StoreState {
        try ensureDirectoryExists(at: directoryURL, fileManager: fileManager)
        var records: [String: DownloadTaskPersistence.Record] = [:]
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
            } catch {
                quarantineFileIfNeeded(checkpointURL, fileManager: fileManager)
            }
        }

        if fileManager.fileExists(atPath: logURL.path()) {
            let replayResult = try replayLog(at: logURL, onto: records, fileManager: fileManager)
            records = replayResult.records
            nextSequence = replayResult.nextSequence
            logEventCount = replayResult.logEventCount
            tombstoneCount = replayResult.tombstoneCount
        }

        return StoreState(
            records: records,
            nextSequence: nextSequence,
            logEventCount: logEventCount,
            tombstoneCount: tombstoneCount,
            logSize: fileSize(at: logURL, fileManager: fileManager)
        )
    }

    private static func replayLog(
        at logURL: URL,
        onto initialRecords: [String: DownloadTaskPersistence.Record],
        fileManager: FileManager
    ) throws -> (records: [String: DownloadTaskPersistence.Record], nextSequence: Int64, logEventCount: Int, tombstoneCount: Int) {
        var records = initialRecords
        var nextSequence: Int64 = 0
        var logEventCount = 0
        var tombstoneCount = 0

        let data = try Data(contentsOf: logURL)
        guard !data.isEmpty else {
            return (records, nextSequence, logEventCount, tombstoneCount)
        }

        guard let contents = String(data: data, encoding: .utf8) else {
            quarantineFileIfNeeded(logURL, fileManager: fileManager)
            return (records, nextSequence, logEventCount, tombstoneCount)
        }

        let lines = contents.split(whereSeparator: \.isNewline)
        var validPrefixEvents: [Event] = []

        for line in lines {
            do {
                let event = try JSONDecoder().decode(Event.self, from: Data(line.utf8))
                validPrefixEvents.append(event)
            } catch {
                quarantineFileIfNeeded(logURL, fileManager: fileManager)
                break
            }
        }

        for event in validPrefixEvents {
            switch event.kind {
            case .upsert:
                guard let url = event.url, let destinationURL = event.destinationURL else { continue }
                records[event.taskID] = DownloadTaskPersistence.Record(
                    id: event.taskID,
                    url: url,
                    destinationURL: destinationURL
                )
            case .remove:
                records.removeValue(forKey: event.taskID)
                tombstoneCount += 1
            }
            nextSequence = max(nextSequence, event.sequence + 1)
            logEventCount += 1
        }

        if validPrefixEvents.count != lines.count {
            try resetLog(at: logURL, fileManager: fileManager)
        }

        return (records, nextSequence, logEventCount, tombstoneCount)
    }

    private static func append(events: [Event], to logURL: URL, fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: logURL.path()) {
            try Data().write(to: logURL)
        }

        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()

        let encoder = JSONEncoder()
        for event in events {
            let data = try encoder.encode(event)
            handle.write(data)
            handle.write(Data([0x0A]))
        }
    }

    private static func writeCheckpoint(
        records: [String: DownloadTaskPersistence.Record],
        to checkpointURL: URL,
        fileManager: FileManager
    ) throws {
        let envelope = Envelope(version: 1, records: records)
        let data = try JSONEncoder().encode(envelope)
        try writeAtomically(data: data, to: checkpointURL, fileManager: fileManager)
    }

    private static func writeAtomically(data: Data, to fileURL: URL, fileManager: FileManager) throws {
        let tempURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("tmp-\(UUID().uuidString)")

        try data.write(to: tempURL, options: .atomic)

        if fileManager.fileExists(atPath: fileURL.path()) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: fileURL)
        }
    }

    private static func resetLog(at logURL: URL, fileManager: FileManager) throws {
        let emptyData = Data()
        try writeAtomically(data: emptyData, to: logURL, fileManager: fileManager)
    }

    private static func shouldCompact(state: StoreState) -> Bool {
        if state.logEventCount >= 1_000 {
            return true
        }

        if state.logSize >= 1_048_576 {
            return true
        }

        guard state.logEventCount > 0 else { return false }
        let tombstoneRatio = Double(state.tombstoneCount) / Double(state.logEventCount)
        return tombstoneRatio >= 0.25
    }

    private static func fileSize(at url: URL, fileManager: FileManager) -> UInt64 {
        guard
            fileManager.fileExists(atPath: url.path()),
            let attributes = try? fileManager.attributesOfItem(atPath: url.path()),
            let fileSize = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return fileSize.uint64Value
    }

    private static func quarantineFileIfNeeded(_ url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path()) else { return }
        let timestamp = Int(Date.now.timeIntervalSince1970)
        let directory = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let corruptedURL = directory.appendingPathComponent(
            ext.isEmpty ? "\(name).corrupted-\(timestamp)" : "\(name).corrupted-\(timestamp).\(ext)",
            isDirectory: false
        )
        try? fileManager.moveItem(at: url, to: corruptedURL)
    }

    private static func withDirectoryLock<T>(
        lockURL: URL,
        fileManager: FileManager,
        _ work: () throws -> T
    ) throws -> T {
        try ensureDirectoryExists(at: lockURL.deletingLastPathComponent(), fileManager: fileManager)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw CocoaError(.fileLocking)
        }
        defer { flock(descriptor, LOCK_UN) }

        return try work()
    }
}
