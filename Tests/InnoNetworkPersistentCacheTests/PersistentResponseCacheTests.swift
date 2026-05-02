import Foundation
import InnoNetwork
import InnoNetworkPersistentCache
import Testing

@Suite("Persistent Response Cache Tests")
struct PersistentResponseCacheTests {
    @Test("Cache persists entries across actor instances")
    func persistsAcrossInstances() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/user")
        let response = CachedResponse(data: Data("cached".utf8), headers: ["ETag": "v1"])

        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, response)

        let reader = try PersistentResponseCache(configuration: configuration)
        let cached = try #require(await reader.get(key))

        #expect(cached.data == response.data)
        #expect(cached.headers["ETag"] == "v1")
    }

    @Test("Default policy rejects authenticated and Set-Cookie responses")
    func rejectsPrivateResponsesByDefault() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let authenticatedKey = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Authorization": "Bearer secret"]
        )
        let cookieKey = ResponseCacheKey(method: "GET", url: "https://example.com/cookie")

        await cache.set(authenticatedKey, CachedResponse(data: Data("private".utf8)))
        await cache.set(cookieKey, CachedResponse(data: Data("cookie".utf8), headers: ["Set-Cookie": "sid=1"]))

        #expect(await cache.get(authenticatedKey) == nil)
        #expect(await cache.get(cookieKey) == nil)
    }

    @Test("Evicts least recently used entries when over budget")
    func evictsLeastRecentlyUsedEntries() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                maxBytes: 32,
                maxEntries: 10,
                maxEntryBytes: 32
            )
        )
        let first = ResponseCacheKey(method: "GET", url: "https://example.com/1")
        let second = ResponseCacheKey(method: "GET", url: "https://example.com/2")

        await cache.set(first, CachedResponse(data: Data(repeating: 1, count: 24)))
        // 1 ms is below the modification-time resolution on APFS / macOS
        // CI runners, so the LRU comparison can tie and the wrong entry
        // gets evicted. 50 ms gives the index touch a stable ordering.
        try await Task.sleep(for: .milliseconds(50))
        await cache.set(second, CachedResponse(data: Data(repeating: 2, count: 24)))

        #expect(await cache.get(first) == nil)
        #expect(await cache.get(second) != nil)
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

    @Test("get() returns the cached response when index persistence fails")
    func getReturnsValueWhenIndexPersistenceFails() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/persist-fail")

        await cache.set(key, CachedResponse(data: Data("payload".utf8)))

        // Simulate read-only state by replacing the index file with a directory entry.
        let indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: indexURL) }

        let cached = try #require(await cache.get(key))
        #expect(cached.data == Data("payload".utf8))
    }

    @Test("persistenceFsyncPolicy=.always still persists across reopen")
    func fsyncAlwaysPersistsAcrossReopen() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(
            directoryURL: directory,
            persistenceFsyncPolicy: .always
        )
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/fsynced")

        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: Data("durable".utf8)))

        let reader = try PersistentResponseCache(configuration: configuration)
        let cached = try #require(await reader.get(key))
        #expect(cached.data == Data("durable".utf8))
    }

    @Test("PersistentResponseCacheConfiguration defaults to .onCheckpoint")
    func defaultFsyncPolicyIsOnCheckpoint() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        #expect(configuration.persistenceFsyncPolicy == .onCheckpoint)
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("innonetwork-persistent-cache-\(UUID().uuidString)", isDirectory: true)
    }
}
