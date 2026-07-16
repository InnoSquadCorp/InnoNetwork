import Foundation
import OSLog

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
        bodiesDirectoryURL: URL,
        fileManager: FileManager
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
            removeBody(fileName: entry.bodyFileName, in: bodiesDirectoryURL, fileManager: fileManager)
        }
        try persistIndex(
            scrubbedIndex,
            to: indexURL,
            directoryURL: configuration.directoryURL,
            configuration: configuration,
            fileManager: fileManager
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
        storageIO: StorageIO
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
                fileManager: fileManager
            )
            for bodyFileName in removableBodyFileNames {
                removeBody(
                    fileName: bodyFileName,
                    in: bodiesDirectoryURL,
                    fileManager: fileManager
                )
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
        fileManager: FileManager
    ) -> Int {
        let referencedBodyFileNames = Set(loadedIndex.entries.values.map(\.bodyFileName))
        let bodyURLs: [URL]
        do {
            bodyURLs = try fileManager.contentsOfDirectory(
                at: bodiesDirectoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            logger.warning(
                "persistent_cache_body_sweep_enumeration_failed error=\(String(describing: error), privacy: .private)"
            )
            return 0
        }

        var scrubbedCount = 0
        var deleteFailureCount = 0
        for bodyURL in bodyURLs {
            let resourceValues = try? bodyURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            let isCacheBodyEntry =
                resourceValues?.isRegularFile == true
                || resourceValues?.isSymbolicLink == true
            guard isCacheBodyEntry, bodyURL.pathExtension == "body" else { continue }
            guard !referencedBodyFileNames.contains(bodyURL.lastPathComponent) else { continue }
            do {
                try fileManager.removeItem(at: bodyURL)
                scrubbedCount += 1
            } catch {
                deleteFailureCount += 1
                logger.debug(
                    "persistent_cache_body_sweep_delete_failed file=\(bodyURL.lastPathComponent, privacy: .public) error=\(String(describing: error), privacy: .private)"
                )
                continue
            }
        }
        if deleteFailureCount > 0 {
            logger.warning(
                "persistent_cache_body_sweep_delete_failures count=\(deleteFailureCount, privacy: .public)"
            )
        }
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
        storageIO: StorageIO
    ) throws -> OpenResult {
        let data: Data
        do {
            data = try storageIO.indexReader(indexURL)
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
                fileManager: fileManager
            )
            return OpenResult(
                index: Index(version: formatVersion, entries: [:]),
                telemetryEvents: []
            )
        }

        let bodiesDirectoryURL = directoryURL.appendingPathComponent("bodies", isDirectory: true)

        // The cache is best-effort durable: corrupt indexes and unknown
        // index versions both fall through to the same self-healing reset
        // path. Version 3 changed cache-key semantics to preserve query-item
        // order; older entries are intentionally cold-reset because two
        // wire-distinct targets may have occupied the same version-2 slot.
        if let index = try? JSONDecoder.persistentCache.decode(Index.self, from: data),
            index.version == formatVersion
        {
            return OpenResult(index: index, telemetryEvents: [])
        }

        try resetCacheStorage(
            indexURL: indexURL,
            bodiesDirectoryURL: bodiesDirectoryURL,
            dataProtectionClass: dataProtectionClass,
            fileManager: fileManager
        )
        return OpenResult(index: Index(version: formatVersion, entries: [:]), telemetryEvents: [])
    }

    static func resetCacheStorage(
        indexURL: URL,
        bodiesDirectoryURL: URL,
        dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass,
        fileManager: FileManager
    ) throws {
        try? fileManager.removeItem(at: indexURL)
        try? fileManager.removeItem(at: bodiesDirectoryURL)
        try fileManager.createDirectory(at: bodiesDirectoryURL, withIntermediateDirectories: true)
        applyDataProtection(dataProtectionClass, to: bodiesDirectoryURL, fileManager: fileManager)
    }

    static func applyDataProtectionToExistingCacheFiles(
        dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass,
        indexURL: URL,
        bodiesDirectoryURL: URL,
        fileManager: FileManager
    ) {
        if fileManager.fileExists(atPath: indexURL.path) {
            applyDataProtection(dataProtectionClass, to: indexURL, fileManager: fileManager)
        }
        guard
            let bodyURLs = try? fileManager.contentsOfDirectory(
                at: bodiesDirectoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }

        for bodyURL in bodyURLs {
            let resourceValues = try? bodyURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard
                resourceValues?.isRegularFile == true,
                resourceValues?.isSymbolicLink != true
            else { continue }
            applyDataProtection(dataProtectionClass, to: bodyURL, fileManager: fileManager)
        }
    }
}
