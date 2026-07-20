import Foundation
import InnoNetwork
import Testing

@testable import InnoNetworkPersistentCache

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Security)
import Security
#endif

extension PersistentResponseCacheTests {
    @Test("statistics snapshot exposes entry and byte budgets")
    func statisticsSnapshotExposesBudgets() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                maxBytes: 128,
                maxEntries: 3,
                maxEntryBytes: 64
            )
        )
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/stats")

        await cache.set(key, CachedResponse(data: Data("stats".utf8), headers: ["ETag": "v1"]))

        let stats = await cache.statistics()
        #expect(stats.entryCount == 1)
        #expect(stats.byteCount == 11)
        #expect(stats.maxEntries == 3)
        #expect(stats.maxBytes == 128)
    }

    @Test("statistics tracks hit and miss counts across get() calls")
    func statisticsTracksHitAndMissCounts() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                maxBytes: 1024,
                maxEntries: 8,
                maxEntryBytes: 512
            )
        )
        let storedKey = ResponseCacheKey(method: "GET", url: "https://example.com/hit")
        let missingKey = ResponseCacheKey(method: "GET", url: "https://example.com/miss")
        await cache.set(storedKey, CachedResponse(data: Data("hit-body".utf8)))

        _ = await cache.get(storedKey)
        _ = await cache.get(storedKey)
        _ = await cache.get(missingKey)

        let stats = await cache.statistics()
        #expect(stats.hitCount == 2)
        #expect(stats.missCount == 1)
    }

    @Test("statistics tracks eviction counts when budget enforcement fires")
    func statisticsTracksEvictionCounts() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                maxBytes: 1024,
                maxEntries: 2,
                maxEntryBytes: 512
            )
        )
        let key1 = ResponseCacheKey(method: "GET", url: "https://example.com/a")
        let key2 = ResponseCacheKey(method: "GET", url: "https://example.com/b")
        let key3 = ResponseCacheKey(method: "GET", url: "https://example.com/c")
        await cache.set(key1, CachedResponse(data: Data("a".utf8)))
        await cache.set(key2, CachedResponse(data: Data("b".utf8)))
        let priorEvictions = await cache.statistics().evictionCount
        await cache.set(key3, CachedResponse(data: Data("c".utf8)))

        let stats = await cache.statistics()
        #expect(stats.entryCount == 2)
        #expect(stats.evictionCount == priorEvictions + 1)
    }

    @Test("get() missing body records scrub telemetry and eviction count")
    func getMissingBodyRecordsTelemetryAndEvictionCount() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/missing-body")
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        await cache.set(key, CachedResponse(data: Data("missing".utf8)))
        let bodyURL = try #require(existingBodyURLs(in: directory).first)
        try FileManager.default.removeItem(at: bodyURL)
        let priorEvictions = await cache.statistics().evictionCount

        #expect(await cache.get(key) == nil)

        let stats = await cache.statistics()
        #expect(stats.evictionCount == priorEvictions + 1)
        #expect(
            await cache.telemetrySnapshot()
                .contains(.scrubbedEntries(reason: .missingBody, count: 1, byteCount: 7))
        )
    }

    @Test("get() drops a body that grew past maxEntryBytes after init")
    func getDropsBodyThatExceedsMaxEntryBytesAfterInit() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/grown-body")
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                maxEntryBytes: 64
            )
        )
        await cache.set(key, CachedResponse(data: Data(repeating: 1, count: 8)))
        let bodyURL = try #require(existingBodyURLs(in: directory).first)

        try Data(repeating: 9, count: 128).write(to: bodyURL, options: .atomic)
        let boundedRead = try await PersistentResponseCache.readBodyData(
            fileName: bodyURL.lastPathComponent,
            in: directory.appendingPathComponent("bodies", isDirectory: true),
            maximumByteCount: 64
        )
        #expect(boundedRead.count == 65)
        let priorEvictions = await cache.statistics().evictionCount

        #expect(await cache.get(key) == nil)
        #expect(try existingBodyURLs(in: directory).isEmpty)
        #expect(try indexEntryCount(in: directory) == 0)
        #expect(await cache.statistics().evictionCount == priorEvictions + 1)
        #expect(
            await cache.telemetrySnapshot()
                .contains(.scrubbedEntries(reason: .entryTooLarge, count: 1, byteCount: 8))
        )
    }

    @Test("Unknown index version is evicted and startup continues")
    func unknownVersionEvictsAndContinues() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let indexURL = directory.appendingPathComponent("index.json")
        try Data(#"{"version":999,"entries":{}}"#.utf8).write(to: indexURL)

        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/recovered")
        await cache.set(key, CachedResponse(data: Data("ok".utf8)))

        #expect(await cache.get(key) != nil)
    }

    @Test("Version 3 index cold-resets before query HMAC storage")
    func versionThreeIndexColdResets() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let legacyKey = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/items?a=1&b=2"
        )

        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(legacyKey, CachedResponse(data: Data("legacy".utf8)))
        #expect(try existingBodyURLs(in: directory).count == 1)

        var index = try indexObject(in: directory)
        index["version"] = 3
        let indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
        let legacyIndexData = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
        try legacyIndexData.write(to: indexURL, options: .atomic)

        let reopened = try PersistentResponseCache(configuration: configuration)
        #expect(await reopened.get(legacyKey) == nil)
        #expect(try existingBodyURLs(in: directory).isEmpty)

        let newKey = ResponseCacheKey(method: "GET", url: "https://example.com/recovered")
        await reopened.set(newKey, CachedResponse(data: Data("new".utf8)))
        #expect(try indexObject(in: directory)["version"] as? Int == 4)
    }

    @Test("Recovery preserves unrelated files in the cache directory")
    func recoveryDoesNotWipeUserDirectory() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let indexURL = directory.appendingPathComponent("index.json")
        try Data(#"{"version":999,"entries":{}}"#.utf8).write(to: indexURL)

        let sentinelURL = directory.appendingPathComponent("sentinel.txt")
        try Data("keep-me".utf8).write(to: sentinelURL)

        _ = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )

        #expect(FileManager.default.fileExists(atPath: sentinelURL.path))
    }

    @Test("Recovery preserves unrelated files when index is corrupt")
    func recoveryFromCorruptIndexDoesNotWipeUserDirectory() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let indexURL = directory.appendingPathComponent("index.json")
        try Data("not-json".utf8).write(to: indexURL)

        let sentinelURL = directory.appendingPathComponent("sentinel.txt")
        try Data("keep-me".utf8).write(to: sentinelURL)

        _ = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )

        #expect(FileManager.default.fileExists(atPath: sentinelURL.path))
    }

    @Test("Recovery reapplies data protection to recreated body directory")
    func recoveryReappliesDataProtectionToRecreatedBodiesDirectory() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = PersistentCacheProtectionWriteRecorder()
        let fileManager = PersistentCacheRecordingFileManager(recorder: recorder)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let indexURL = directory.appendingPathComponent("index.json")
        try Data(#"{"version":999,"entries":{}}"#.utf8).write(to: indexURL)

        _ = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory),
            fileManager: fileManager
        )

        let bodiesURL = directory.appendingPathComponent("bodies", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: bodiesURL.path))
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        #expect(
            recorder.protectionWrites(for: bodiesURL.path)
                == [.completeUntilFirstUserAuthentication, .completeUntilFirstUserAuthentication]
        )
        #else
        #expect(recorder.protectionWrites(for: bodiesURL.path).isEmpty)
        #endif
    }

    @Test("Overwriting an entry preserves the freshly written body")
    func overwriteKeepsFreshBody() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/overwrite")

        await cache.set(key, CachedResponse(data: Data("first".utf8)))
        await cache.set(key, CachedResponse(data: Data("second".utf8)))

        let cached = try #require(await cache.get(key))
        #expect(cached.data == Data("second".utf8))
    }

    @Test("Overwrite updates byte budget before eviction")
    func overwriteUpdatesByteBudgetBeforeEviction() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                maxBytes: 64,
                maxEntries: 10,
                maxEntryBytes: 64
            )
        )
        let overwritten = ResponseCacheKey(method: "GET", url: "https://example.com/overwrite-budget")
        let peer = ResponseCacheKey(method: "GET", url: "https://example.com/peer-budget")

        await cache.set(overwritten, CachedResponse(data: Data(repeating: 1, count: 40)))
        await cache.set(overwritten, CachedResponse(data: Data(repeating: 2, count: 1)))
        await cache.set(peer, CachedResponse(data: Data(repeating: 3, count: 40)))

        #expect(await cache.get(overwritten) != nil)
        #expect(await cache.get(peer) != nil)
    }

    @Test("get() returns the cached response when index persistence fails")
    func getReturnsValueWhenIndexPersistenceFails() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let maintenanceFailures = PersistentCacheMaintenanceFailureRecorder()
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory),
            fileManager: .default,
            storageIO: PersistentResponseCache.StorageIO(),
            maintenanceFailureObserver: { operation in
                maintenanceFailures.record(operation)
            }
        )
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/persist-fail")

        await cache.set(key, CachedResponse(data: Data("payload".utf8)))

        // Simulate read-only state by replacing the index file with a directory entry.
        let indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: indexURL) }

        for _ in 0..<32 {
            let cached = try #require(await cache.get(key))
            #expect(cached.data == Data("payload".utf8))
        }
        #expect(maintenanceFailures.snapshot() == [.flushReadMetadata])
    }

    @Test("set() preserves the old entry when index persistence fails during overwrite")
    func setPreservesOldEntryWhenIndexPersistenceFailsDuringOverwrite() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/overwrite-persist-fail")

        await cache.set(key, CachedResponse(data: Data("first".utf8)))
        let indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
        let persistedIndex = try Data(contentsOf: indexURL)
        let originalBodyURLs = try existingBodyURLs(in: directory)
        #expect(originalBodyURLs.count == 1)

        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: false)

        await cache.set(key, CachedResponse(data: Data("second".utf8)))

        let cached = try #require(await cache.get(key))
        #expect(cached.data == Data("first".utf8))
        #expect(try existingBodyURLs(in: directory) == originalBodyURLs)

        try FileManager.default.removeItem(at: indexURL)
        try persistedIndex.write(to: indexURL, options: .atomic)

        let reopened = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let reopenedCached = try #require(await reopened.get(key))
        #expect(reopenedCached.data == Data("first".utf8))
    }

    @Test("set() preserves eviction candidates when index persistence fails")
    func setPreservesEvictionCandidatesWhenIndexPersistenceFails() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                maxBytes: 96,
                maxEntries: 10,
                maxEntryBytes: 96
            )
        )
        let first = ResponseCacheKey(method: "GET", url: "https://example.com/eviction-persist-fail-1")
        let second = ResponseCacheKey(method: "GET", url: "https://example.com/eviction-persist-fail-2")
        let third = ResponseCacheKey(method: "GET", url: "https://example.com/eviction-persist-fail-3")

        await cache.set(first, CachedResponse(data: Data(repeating: 1, count: 32)))
        try await Task.sleep(for: .milliseconds(50))
        await cache.set(second, CachedResponse(data: Data(repeating: 2, count: 32)))
        let originalBodyURLs = try existingBodyURLs(in: directory)
        #expect(originalBodyURLs.count == 2)

        let indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: false)

        await cache.set(third, CachedResponse(data: Data(repeating: 3, count: 80)))

        #expect(await cache.get(first) != nil)
        #expect(await cache.get(second) != nil)
        #expect(await cache.get(third) == nil)
        #expect(try existingBodyURLs(in: directory) == originalBodyURLs)
    }

}
