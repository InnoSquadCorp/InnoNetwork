import Foundation
import OSLog

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Split out of `PersistentResponseCache.swift` so the open-time recovery
// pipeline — policy-rejected scrub, budget enforcement, unreferenced-body
// sweep, index load, and cold-start reset — lives in one place. All helpers
// stay `static` and share the body-file admission rules from `+IO.swift`.
extension PersistentResponseCache {

    static func reindexVaryVariantsOnOpen(
        _ loadedIndex: Index,
        encoder: JSONEncoder
    ) throws -> Index {
        var entries: [String: Entry] = [:]
        for (_, entry) in loadedIndex.entries {
            let id = try identifier(for: entry.key, varyHeaders: entry.varyHeaders, encoder: encoder)
            if let existing = entries[id], existing.lastAccessedAt >= entry.lastAccessedAt {
                continue
            }
            entries[id] = entry
        }
        return Index(version: loadedIndex.version, entries: entries)
    }

    static func scrubPolicyRejectedEntriesOnOpen(
        _ loadedIndex: Index,
        configuration: PersistentResponseCacheConfiguration,
        indexURL: URL,
        fileManager: FileManager,
        storage: AnchoredStorage
    ) throws -> OpenResult {
        var scrubbedIndex = loadedIndex
        let rejectedEntries = loadedIndex.entries.filter { _, entry in
            !shouldStore(key: entry.key, responseHeaders: entry.headers, configuration: configuration)
        }
        guard !rejectedEntries.isEmpty else {
            return OpenResult(index: loadedIndex, telemetryEvents: [])
        }

        var removedBytes = 0
        for (id, entry) in rejectedEntries {
            scrubbedIndex.entries.removeValue(forKey: id)
            removedBytes += entry.byteCost
            removeBody(fileName: entry.bodyFileName, storage: storage)
        }
        try persistIndex(
            scrubbedIndex,
            to: indexURL,
            directoryURL: configuration.directoryURL,
            configuration: configuration,
            fileManager: fileManager,
            storage: storage
        )
        return OpenResult(
            index: scrubbedIndex,
            telemetryEvents: [
                .scrubbedEntries(
                    reason: .policyRejected,
                    count: rejectedEntries.count,
                    byteCount: removedBytes
                )
            ]
        )
    }

    static func enforceBudgetsOnOpen(
        _ loadedIndex: Index,
        configuration: PersistentResponseCacheConfiguration,
        indexURL: URL,
        bodiesDirectoryURL: URL,
        fileManager: FileManager,
        storageIO: StorageIO,
        storage: AnchoredStorage
    ) throws -> OpenResult {
        var budgetedIndex = loadedIndex
        var didMutate = false
        var removableBodyFileNames: [String] = []
        var scrubbedMissingCount = 0
        var scrubbedMissingBytes = 0
        var scrubbedOversizedCount = 0
        var scrubbedOversizedBytes = 0
        var evictedCount = 0
        var evictedBytes = 0

        for (id, entry) in loadedIndex.entries {
            let bodySize: Int
            do {
                bodySize = try storageIO.bodyInspector(
                    storage,
                    entry.bodyFileName,
                    bodiesDirectoryURL
                )
            } catch {
                guard shouldScrubBody(after: error) else {
                    throw error
                }
                budgetedIndex.entries.removeValue(forKey: id)
                scrubbedMissingCount += 1
                scrubbedMissingBytes += entry.byteCost
                didMutate = true
                continue
            }
            if bodySize > configuration.maxEntryBytes {
                budgetedIndex.entries.removeValue(forKey: id)
                removableBodyFileNames.append(entry.bodyFileName)
                scrubbedOversizedCount += 1
                scrubbedOversizedBytes += entry.byteCost
                didMutate = true
            }
        }

        let sortedIDs = budgetedIndex.entries.keys.sorted { lhs, rhs in
            let lhsDate = budgetedIndex.entries[lhs]?.lastAccessedAt ?? .distantPast
            let rhsDate = budgetedIndex.entries[rhs]?.lastAccessedAt ?? .distantPast
            return lhsDate < rhsDate
        }
        var cursor = sortedIDs.startIndex
        var runningTotalBytes = totalBytes(in: budgetedIndex)
        while cursor < sortedIDs.endIndex,
            budgetedIndex.entries.count > configuration.maxEntries
                || runningTotalBytes > configuration.maxBytes
        {
            let victimID = sortedIDs[cursor]
            cursor = sortedIDs.index(after: cursor)
            guard let victim = budgetedIndex.entries.removeValue(forKey: victimID) else { continue }
            runningTotalBytes -= victim.byteCost
            removableBodyFileNames.append(victim.bodyFileName)
            evictedCount += 1
            evictedBytes += victim.byteCost
            didMutate = true
        }

        if didMutate {
            try persistIndex(
                budgetedIndex,
                to: indexURL,
                directoryURL: configuration.directoryURL,
                configuration: configuration,
                fileManager: fileManager,
                storage: storage
            )
            for bodyFileName in removableBodyFileNames {
                removeBody(fileName: bodyFileName, storage: storage)
            }
        }
        var telemetry: [PersistentResponseCacheTelemetryEvent] = []
        if scrubbedMissingCount > 0 {
            telemetry.append(
                .scrubbedEntries(
                    reason: .missingBody,
                    count: scrubbedMissingCount,
                    byteCount: scrubbedMissingBytes
                )
            )
        }
        if scrubbedOversizedCount > 0 {
            telemetry.append(
                .scrubbedEntries(
                    reason: .entryTooLarge,
                    count: scrubbedOversizedCount,
                    byteCount: scrubbedOversizedBytes
                )
            )
        }
        if evictedCount > 0 {
            telemetry.append(
                .scrubbedEntries(
                    reason: .storageBudget,
                    count: evictedCount,
                    byteCount: evictedBytes
                )
            )
        }
        return OpenResult(index: budgetedIndex, telemetryEvents: telemetry)
    }

    @discardableResult
    static func scrubUnreferencedBodiesOnOpen(
        _ loadedIndex: Index,
        bodiesDirectoryURL: URL,
        fileManager: FileManager,
        storage: AnchoredStorage
    ) -> Int {
        let referencedBodyFileNames = Set(loadedIndex.entries.values.map(\.bodyFileName))
        let bodyFileNames: [String]
        do {
            bodyFileNames = try storage.bodyEntryNames()
        } catch {
            logger.warning(
                "persistent_cache_body_sweep_enumeration_failed error=\(String(describing: error), privacy: .private)"
            )
            return 0
        }

        var scrubbedCount = 0
        var deleteFailureCount = 0
        for bodyFileName in bodyFileNames {
            guard !referencedBodyFileNames.contains(bodyFileName) else { continue }
            let information: stat
            do {
                guard let entryInformation = try storage.bodyEntryInformation(named: bodyFileName) else {
                    continue
                }
                information = entryInformation
            } catch {
                deleteFailureCount += 1
                continue
            }
            let type = information.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFLNK || type == S_IFIFO else { continue }
            guard bodyFileName.hasSuffix(".body") else { continue }
            if storage.removeBody(fileName: bodyFileName) {
                scrubbedCount += 1
            } else if errno != ENOENT {
                deleteFailureCount += 1
                logger.debug(
                    "persistent_cache_body_sweep_delete_failed file=\(bodyFileName, privacy: .public) errno=\(errno, privacy: .public)"
                )
            }
        }
        if deleteFailureCount > 0 {
            logger.warning(
                "persistent_cache_body_sweep_delete_failures count=\(deleteFailureCount, privacy: .public)"
            )
        }
        _ = (bodiesDirectoryURL, fileManager)
        return scrubbedCount
    }

    static func totalBytes(in index: Index) -> Int {
        index.entries.values.reduce(0) { $0 + $1.byteCost }
    }

    static func loadIndex(
        from indexURL: URL,
        directoryURL: URL,
        dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass,
        fileManager: FileManager,
        storageIO: StorageIO,
        storage: AnchoredStorage
    ) throws -> OpenResult {
        let data: Data
        do {
            data = try storageIO.indexReader(storage, indexURL)
        } catch {
            if isMissingFileError(error) {
                return OpenResult(
                    index: Index(version: formatVersion, entries: [:]),
                    telemetryEvents: []
                )
            }
            guard shouldResetIndex(after: error) else { throw error }
            let bodiesDirectoryURL = directoryURL.appendingPathComponent("bodies", isDirectory: true)
            try resetCacheStorage(
                indexURL: indexURL,
                bodiesDirectoryURL: bodiesDirectoryURL,
                dataProtectionClass: dataProtectionClass,
                fileManager: fileManager,
                storage: storage
            )
            return OpenResult(
                index: Index(version: formatVersion, entries: [:]),
                telemetryEvents: []
            )
        }

        let bodiesDirectoryURL = directoryURL.appendingPathComponent("bodies", isDirectory: true)

        // The cache is best-effort durable: corrupt indexes and unknown
        // index versions both fall through to the same self-healing reset
        // path. Version 4 HMAC-protects the raw query while retaining its
        // ordering in the digest input. Version-3 indexes are intentionally
        // cold-reset so raw query material does not survive the upgrade.
        if let index = try? JSONDecoder.persistentCache.decode(Index.self, from: data),
            index.version == formatVersion
        {
            return OpenResult(index: index, telemetryEvents: [])
        }

        try resetCacheStorage(
            indexURL: indexURL,
            bodiesDirectoryURL: bodiesDirectoryURL,
            dataProtectionClass: dataProtectionClass,
            fileManager: fileManager,
            storage: storage
        )
        return OpenResult(index: Index(version: formatVersion, entries: [:]), telemetryEvents: [])
    }

    static func resetCacheStorage(
        indexURL: URL,
        bodiesDirectoryURL: URL,
        dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass,
        fileManager: FileManager,
        storage: AnchoredStorage
    ) throws {
        storage.removeRootEntry(named: "index.json")
        try storage.resetBodies()
        _ = (indexURL, bodiesDirectoryURL, dataProtectionClass, fileManager)
    }

}
