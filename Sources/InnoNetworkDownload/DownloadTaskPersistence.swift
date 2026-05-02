import Darwin
import Foundation

package protocol DownloadTaskStore: Actor {
    func upsert(id: String, url: URL, destinationURL: URL, resumeData: Data?) async throws
    func updateResumeData(id: String, resumeData: Data?) async throws
    func remove(id: String) async throws
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
        let resumeData: Data?
    }

    private struct StoreState: Sendable {
        var records: [String: DownloadTaskPersistence.Record]
        // Reverse index from source URL → task id so `id(forURL:)` is O(1).
        // The append-log already enforces that `records[id]` is the
        // authoritative record; this index is rebuilt on load and kept in
        // sync on every mutate so it never lies about authoritative state.
        var urlToID: [URL: String]
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
        let directoryURL =
            baseDirectory
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
            initialState = StoreState(
                records: [:],
                urlToID: [:],
                nextSequence: 0,
                logEventCount: 0,
                tombstoneCount: 0,
                logSize: 0
            )
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
            // different URL for this id. Re-mapping `urlToID` for the new URL
            // happens unconditionally below.
            if let existing = $0.records[id], existing.url != url {
                if $0.urlToID[existing.url] == id {
                    $0.urlToID.removeValue(forKey: existing.url)
                }
            }
            $0.records[id] = DownloadTaskPersistence.Record(
                id: id,
                url: url,
                destinationURL: destinationURL,
                resumeData: resumeData
            )
            $0.urlToID[url] = id
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
        guard let existing = state.records[id] else { return }
        try await upsert(
            id: existing.id, url: existing.url, destinationURL: existing.destinationURL, resumeData: resumeData)
    }

    package func remove(id: String) async throws {
        guard state.records[id] != nil else { return }
        try await mutate {
            if let existing = $0.records.removeValue(forKey: id),
                $0.urlToID[existing.url] == id {
                $0.urlToID.removeValue(forKey: existing.url)
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

    package func record(forID id: String) async -> DownloadTaskPersistence.Record? {
        state.records[id]
    }

    package func allRecords() async -> [DownloadTaskPersistence.Record] {
        Array(state.records.values)
    }

    package func id(forURL url: URL?) async -> String? {
        guard let url else { return nil }
        return state.urlToID[url]
    }

    package func prune(keeping ids: Set<String>) async throws {
        try await mutate { state in
            let staleIDs = state.records.keys.filter { !ids.contains($0) }
            guard !staleIDs.isEmpty else { return [] }

            for staleID in staleIDs {
                if let existing = state.records.removeValue(forKey: staleID),
                    state.urlToID[existing.url] == staleID {
                    state.urlToID.removeValue(forKey: existing.url)
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

    private func mutate(_ transform: (inout StoreState) -> [Event]) async throws {
        let fsyncPolicy = self.fsyncPolicy
        let compactionPolicy = self.compactionPolicy
        let fsync = self.fsync
        let updatedState = try Self.withDirectoryLock(lockURL: lockURL, fileManager: fileManager) {
            var diskState = try Self.loadState(
                directoryURL: directoryURL,
                checkpointURL: checkpointURL,
                logURL: logURL,
                fileManager: fileManager
            )

            let events = transform(&diskState)
            guard !events.isEmpty else { return diskState }

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

            return diskState
        }
        state = updatedState
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
            let replayResult = try replayLog(
                at: logURL,
                onto: records,
                checkpointURL: checkpointURL,
                fileManager: fileManager
            )
            records = replayResult.records
            nextSequence = replayResult.nextSequence
            logEventCount = replayResult.logEventCount
            tombstoneCount = replayResult.tombstoneCount
        }

        var urlToID: [URL: String] = [:]
        urlToID.reserveCapacity(records.count)
        for (id, record) in records {
            urlToID[record.url] = id
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

    private static func replayLog(
        at logURL: URL,
        onto initialRecords: [String: DownloadTaskPersistence.Record],
        checkpointURL: URL,
        fileManager: FileManager
    ) throws -> (
        records: [String: DownloadTaskPersistence.Record], nextSequence: Int64, logEventCount: Int, tombstoneCount: Int
    ) {
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
                    destinationURL: destinationURL,
                    resumeData: event.resumeData
                )
            case .remove:
                records.removeValue(forKey: event.taskID)
                tombstoneCount += 1
            }
            nextSequence = max(nextSequence, event.sequence + 1)
            logEventCount += 1
        }

        if validPrefixEvents.count != lines.count {
            // Recovery path: a partial / corrupt suffix of the log forced us
            // to rewrite the checkpoint. fsync defensively so the recovery
            // does not have to be redone if the process crashes again before
            // the OS flushes.
            try writeCheckpoint(
                records: records,
                to: checkpointURL,
                fileManager: fileManager,
                fsyncPolicy: .onCheckpoint,
                fsync: Darwin.fsync
            )
            try resetLog(at: logURL, fileManager: fileManager)
        }

        return (records, nextSequence, logEventCount, tombstoneCount)
    }

    private static func append(
        events: [Event],
        to logURL: URL,
        fileManager: FileManager,
        fsyncPolicy: DownloadConfiguration.PersistenceFsyncPolicy,
        fsync: @Sendable (Int32) -> Int32
    ) throws {
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

        // .always policy forces buffered writes through to stable storage
        // after each append-log mutation batch. .onCheckpoint and .never skip
        // the cost — the next checkpoint or the OS flush is responsible for
        // durability.
        if fsyncPolicy == .always {
            try fsyncFileDescriptor(handle.fileDescriptor, fsync: fsync)
        }
    }

    private static func writeCheckpoint(
        records: [String: DownloadTaskPersistence.Record],
        to checkpointURL: URL,
        fileManager: FileManager,
        fsyncPolicy: DownloadConfiguration.PersistenceFsyncPolicy,
        fsync: @escaping @Sendable (Int32) -> Int32
    ) throws {
        let envelope = Envelope(version: 1, records: records)
        let data = try JSONEncoder().encode(envelope)
        try writeAtomically(
            data: data,
            to: checkpointURL,
            fileManager: fileManager,
            fsyncBeforeRename: fsyncPolicy != .never,
            fsync: fsync
        )
    }

    private static func writeAtomically(
        data: Data,
        to fileURL: URL,
        fileManager: FileManager,
        fsyncBeforeRename: Bool = false,
        fsync: @escaping @Sendable (Int32) -> Int32 = Darwin.fsync
    ) throws {
        let tempURL =
            fileURL
            .deletingPathExtension()
            .appendingPathExtension("tmp-\(UUID().uuidString)")

        try data.write(to: tempURL, options: .atomic)

        // For checkpoint writes (.always or .onCheckpoint), fsync the temp
        // file before the atomic rename so the rename observes a fully
        // committed payload. The empty resetLog path skips the fsync — the
        // log truncation does not need durability beyond what the rename
        // provides.
        if fsyncBeforeRename {
            let handle = try FileHandle(forReadingFrom: tempURL)
            defer { try? handle.close() }
            try fsyncFileDescriptor(handle.fileDescriptor, fsync: fsync)
        }

        if fileManager.fileExists(atPath: fileURL.path()) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: fileURL)
        }

        if fsyncBeforeRename {
            try fsyncParentDirectory(of: fileURL, fsync: fsync)
        }
    }

    private static func resetLog(at logURL: URL, fileManager: FileManager) throws {
        let emptyData = Data()
        try writeAtomically(data: emptyData, to: logURL, fileManager: fileManager)
    }

    private static func fsyncFileDescriptor(
        _ fileDescriptor: Int32,
        fsync: @Sendable (Int32) -> Int32
    ) throws {
        guard fsync(fileDescriptor) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
    }

    private static func fsyncParentDirectory(
        of fileURL: URL,
        fsync: @Sendable (Int32) -> Int32
    ) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        let descriptor = open(directoryURL.path, O_RDONLY)
        guard descriptor >= 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
        defer { close(descriptor) }
        try fsyncFileDescriptor(descriptor, fsync: fsync)
    }

    private static func shouldCompact(
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
        timeout: TimeInterval = 10,
        _ work: () throws -> T
    ) throws -> T {
        try ensureDirectoryExists(at: lockURL.deletingLastPathComponent(), fileManager: fileManager)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }

        // LOCK_EX | LOCK_NB lets us bound the wait. A blocking flock would
        // hang the actor (and any caller awaiting persistence) indefinitely
        // when another process or stuck unit-test holds the lock. We poll
        // every 50ms up to `timeout`, then surface a typed CocoaError so
        // callers see a recoverable failure rather than a deadlock.
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockErrno = errno
            if lockErrno != EWOULDBLOCK && lockErrno != EAGAIN {
                close(descriptor)
                throw CocoaError(.fileLocking)
            }
            if Date() >= deadline {
                close(descriptor)
                throw CocoaError(.fileLocking)
            }
            usleep(50_000)
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        return try work()
    }
}
