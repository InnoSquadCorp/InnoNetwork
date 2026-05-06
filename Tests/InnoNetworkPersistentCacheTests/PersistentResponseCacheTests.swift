import Foundation
import InnoNetwork
import Testing

@testable import InnoNetworkPersistentCache

#if canImport(Darwin)
import Darwin
#endif


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

    @Test("Default policy rejects Cookie request keys")
    func rejectsCookieRequestKeysByDefault() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Cookie": "sid=secret"]
        )

        await cache.set(key, CachedResponse(data: Data("cookie-auth".utf8)))

        #expect(await cache.get(key) == nil)
    }

    @Test("Default policy rejects registered sensitive request keys")
    func rejectsRegisteredSensitiveRequestKeysByDefault() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let headerName = "X-Session-\(UUID().uuidString)"
        ResponseCacheHeaderPolicy.registerSensitiveHeader(headerName)
        defer { ResponseCacheHeaderPolicy.unregisterSensitiveHeader(headerName) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: [headerName: "secret"]
        )

        await cache.set(key, CachedResponse(data: Data("custom-auth".utf8)))

        #expect(await cache.get(key) == nil)
    }

    @Test("Cache-Control private responses are rejected")
    func rejectsCacheControlPrivateResponses() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/private")

        await cache.set(
            key,
            CachedResponse(
                data: Data("private".utf8),
                headers: ["Cache-Control": "max-age=60, private"]
            )
        )

        #expect(await cache.get(key) == nil)
    }

    @Test("Default policy scrubs legacy sensitive entries on open")
    func defaultPolicyScrubsLegacySensitiveEntriesOnOpen() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Cookie": "sid=secret"]
        )
        let permissive = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                storesAuthenticatedResponses: true
            )
        )
        await permissive.set(key, CachedResponse(data: Data("legacy".utf8)))
        #expect(await permissive.get(key) != nil)
        #expect(try existingBodyURLs(in: directory).isEmpty == false)

        _ = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        #expect(try existingBodyURLs(in: directory).isEmpty)
        #expect(try indexEntryCount(in: directory) == 0)

        let reopened = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                storesAuthenticatedResponses: true
            )
        )
        #expect(await reopened.get(key) == nil)
    }

    @Test("Default policy scrubs legacy Set-Cookie entries on open")
    func defaultPolicyScrubsLegacySetCookieEntriesOnOpen() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/cookie")
        let permissive = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                storesSetCookieResponses: true
            )
        )
        await permissive.set(
            key,
            CachedResponse(data: Data("cookie".utf8), headers: ["Set-Cookie": "sid=legacy"])
        )
        #expect(await permissive.get(key) != nil)
        #expect(try existingBodyURLs(in: directory).isEmpty == false)

        _ = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )

        #expect(try existingBodyURLs(in: directory).isEmpty)
        #expect(try indexEntryCount(in: directory) == 0)
    }

    @Test("Default policy scrubs legacy Cache-Control private entries on open")
    func defaultPolicyScrubsLegacyPrivateEntriesOnOpen() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/private-legacy")
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        await cache.set(
            key,
            CachedResponse(data: Data("private".utf8), headers: ["Cache-Control": "max-age=60"])
        )
        #expect(try existingBodyURLs(in: directory).isEmpty == false)

        try rewriteFirstIndexEntryHeaders(
            in: directory,
            headers: ["Cache-Control": "max-age=60, private"]
        )

        _ = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )

        #expect(try existingBodyURLs(in: directory).isEmpty)
        #expect(try indexEntryCount(in: directory) == 0)
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

    @Test("Reopen drops entries that exceed a stricter maxEntryBytes")
    func reopenDropsEntriesExceedingStricterMaxEntryBytes() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/oversized")
        let writer = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                maxEntryBytes: 64
            )
        )
        await writer.set(key, CachedResponse(data: Data(repeating: 1, count: 32)))

        let reopened = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                maxEntryBytes: 16
            )
        )

        #expect(await reopened.get(key) == nil)
        #expect(try existingBodyURLs(in: directory).isEmpty)
        #expect(try indexEntryCount(in: directory) == 0)
    }

    @Test("Reopen enforces stricter entry count budget")
    func reopenEnforcesStricterEntryCountBudget() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                maxEntries: 10,
                maxEntryBytes: 64
            )
        )
        let first = ResponseCacheKey(method: "GET", url: "https://example.com/count-1")
        let second = ResponseCacheKey(method: "GET", url: "https://example.com/count-2")
        let third = ResponseCacheKey(method: "GET", url: "https://example.com/count-3")

        await writer.set(first, CachedResponse(data: Data(repeating: 1, count: 8)))
        await writer.set(second, CachedResponse(data: Data(repeating: 2, count: 8)))
        await writer.set(third, CachedResponse(data: Data(repeating: 3, count: 8)))
        try rewriteIndexEntryAccessTime(
            in: directory,
            url: first.url,
            lastAccessedAt: "2026-05-03T00:00:00Z"
        )
        try rewriteIndexEntryAccessTime(
            in: directory,
            url: second.url,
            lastAccessedAt: "2026-05-03T00:00:01Z"
        )
        try rewriteIndexEntryAccessTime(
            in: directory,
            url: third.url,
            lastAccessedAt: "2026-05-03T00:00:02Z"
        )

        let reopened = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                maxEntries: 1,
                maxEntryBytes: 64
            )
        )

        #expect(await reopened.get(first) == nil)
        #expect(await reopened.get(second) == nil)
        #expect(await reopened.get(third) != nil)
        #expect(try indexEntryCount(in: directory) == 1)
    }

    @Test("Reopen enforces stricter byte budget")
    func reopenEnforcesStricterByteBudget() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                maxBytes: 128,
                maxEntryBytes: 64
            )
        )
        let first = ResponseCacheKey(method: "GET", url: "https://example.com/bytes-1")
        let second = ResponseCacheKey(method: "GET", url: "https://example.com/bytes-2")

        await writer.set(first, CachedResponse(data: Data(repeating: 1, count: 24)))
        await writer.set(second, CachedResponse(data: Data(repeating: 2, count: 24)))
        try rewriteIndexEntryAccessTime(
            in: directory,
            url: first.url,
            lastAccessedAt: "2026-05-03T00:00:00Z"
        )
        try rewriteIndexEntryAccessTime(
            in: directory,
            url: second.url,
            lastAccessedAt: "2026-05-03T00:00:01Z"
        )

        let reopened = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                maxBytes: 32,
                maxEntryBytes: 64
            )
        )

        #expect(await reopened.get(first) == nil)
        #expect(await reopened.get(second) != nil)
        #expect(try indexEntryCount(in: directory) == 1)
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

        #expect(await cache.get(key) == nil)
        #expect(try existingBodyURLs(in: directory).isEmpty)
        #expect(try indexEntryCount(in: directory) == 0)
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

    @Test("Recovery reapplies data protection to recreated body directory")
    func recoveryReappliesDataProtectionToRecreatedBodiesDirectory() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ProtectionWriteRecorder()
        let fileManager = RecordingFileManager(recorder: recorder)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let indexURL = directory.appendingPathComponent("index.json")
        try Data(#"{"version":999,"entries":{}}"#.utf8).write(to: indexURL)

        _ = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory),
            fileManager: fileManager
        )

        let bodiesURL = directory.appendingPathComponent("bodies", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: bodiesURL.path))
        #expect(recorder.protectionWrites(for: bodiesURL.path) == [.completeUnlessOpen, .completeUnlessOpen])
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

    #if canImport(Darwin)
    @Test("F_FULLFSYNC fallback is limited to unsupported descriptors")
    func fullFsyncFallbackIsLimitedToUnsupportedDescriptors() {
        #expect(PersistentResponseCache.isFullFsyncUnsupported(EINVAL))
        #expect(PersistentResponseCache.isFullFsyncUnsupported(EOPNOTSUPP))
        #expect(!PersistentResponseCache.isFullFsyncUnsupported(EIO))
    }
    #endif

    @Test("PersistentResponseCacheConfiguration defaults to completeUnlessOpen protection")
    func defaultDataProtectionClassIsCompleteUnlessOpen() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        #expect(configuration.dataProtectionClass == .completeUnlessOpen)
    }

    @Test("Reopen reapplies data protection to existing index and body files")
    func reopenReappliesDataProtectionToExistingCacheFiles() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/reopen-protection")

        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: Data("protected".utf8)))
        let bodyURLs = try existingBodyURLs(in: directory)
        #expect(bodyURLs.isEmpty == false)

        let recorder = ProtectionWriteRecorder()
        let fileManager = RecordingFileManager(recorder: recorder)
        _ = try PersistentResponseCache(configuration: configuration, fileManager: fileManager)

        let indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
        #expect(recorder.protectionWrites(for: indexURL.path).contains(.completeUnlessOpen))
        for bodyURL in bodyURLs {
            #expect(recorder.protectionWrites(for: bodyURL.path).contains(.completeUnlessOpen))
        }
    }

    @Test("DataProtectionClass.none requests unprotected cache-owned paths")
    func noneDataProtectionRequestsUnprotectedCacheOwnedPaths() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/unprotected")
        let protectedConfiguration = PersistentResponseCacheConfiguration(
            directoryURL: directory,
            dataProtectionClass: .complete
        )
        let writer = try PersistentResponseCache(configuration: protectedConfiguration)
        await writer.set(key, CachedResponse(data: Data("unprotect-me".utf8)))
        let bodyURLs = try existingBodyURLs(in: directory)
        #expect(bodyURLs.isEmpty == false)

        let recorder = ProtectionWriteRecorder()
        let fileManager = RecordingFileManager(recorder: recorder)
        let unprotectedConfiguration = PersistentResponseCacheConfiguration(
            directoryURL: directory,
            dataProtectionClass: .none
        )
        _ = try PersistentResponseCache(configuration: unprotectedConfiguration, fileManager: fileManager)

        let indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
        let bodiesURL = directory.appendingPathComponent("bodies", isDirectory: true)
        #expect(recorder.protectionWrites(for: directory.path).contains(.none))
        #expect(recorder.protectionWrites(for: bodiesURL.path).contains(.none))
        #expect(recorder.protectionWrites(for: indexURL.path).contains(.none))
        for bodyURL in bodyURLs {
            #expect(recorder.protectionWrites(for: bodyURL.path).contains(.none))
        }
    }

    @Test("Body I/O runs off-actor so concurrent gets overlap")
    func bodyReadsRunOffActor() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )

        // Seed two large entries (256 KiB each) so each `Data(contentsOf:)`
        // takes long enough that serialized execution would be measurably
        // slower than parallel execution. Sizes intentionally stay below
        // the default `maxEntryBytes` (5 MiB) so the policy accepts them.
        let payloadCount = 256 * 1024
        let payloadA = Data(repeating: 0xAA, count: payloadCount)
        let payloadB = Data(repeating: 0xBB, count: payloadCount)
        let keyA = ResponseCacheKey(method: "GET", url: "https://example.com/a")
        let keyB = ResponseCacheKey(method: "GET", url: "https://example.com/b")

        await cache.set(keyA, CachedResponse(data: payloadA))
        await cache.set(keyB, CachedResponse(data: payloadB))

        // Issue two `get`s in parallel. Because body reads now run on a
        // detached task, the actor releases its executor while one read is
        // in flight and immediately accepts the second `get` request — the
        // two reads overlap on background threads. The pre-fix actor would
        // serialize them. We assert correctness (both payloads survive
        // round-trip) here; the latency improvement is exercised by the
        // benchmarking suite.
        async let resultA = cache.get(keyA)
        async let resultB = cache.get(keyB)
        let (a, b) = await (resultA, resultB)

        #expect(a?.data == payloadA)
        #expect(b?.data == payloadB)
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("innonetwork-persistent-cache-\(UUID().uuidString)", isDirectory: true)
    }

    private func existingBodyURLs(in directory: URL) throws -> [URL] {
        let bodiesURL = directory.appendingPathComponent("bodies", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(
            at: bodiesURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "body" }
        .sorted { $0.path < $1.path }
    }

    private func indexEntryCount(in directory: URL) throws -> Int {
        let index = try indexObject(in: directory)
        guard let entries = index["entries"] as? [String: Any] else {
            throw testFixtureError("Missing persistent cache index entries")
        }
        return entries.count
    }

    private func rewriteFirstIndexEntryHeaders(in directory: URL, headers: [String: String]) throws {
        var index = try indexObject(in: directory)
        guard var entries = index["entries"] as? [String: Any],
            let entryID = entries.keys.sorted().first,
            var entry = entries[entryID] as? [String: Any]
        else {
            throw testFixtureError("Missing persistent cache entry to rewrite")
        }

        entry["headers"] = headers
        entries[entryID] = entry
        index["entries"] = entries

        let indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
        try data.write(to: indexURL, options: .atomic)
    }

    private func rewriteIndexEntryAccessTime(
        in directory: URL,
        url: String,
        lastAccessedAt: String
    ) throws {
        var index = try indexObject(in: directory)
        guard var entries = index["entries"] as? [String: Any] else {
            throw testFixtureError("Missing persistent cache index entries")
        }
        guard
            let entryID = entries.first(where: { _, value in
                guard let entry = value as? [String: Any],
                    let key = entry["key"] as? [String: Any],
                    let entryURL = key["url"] as? String
                else {
                    return false
                }
                return entryURL == url
            })?.key,
            var entry = entries[entryID] as? [String: Any]
        else {
            throw testFixtureError("Missing persistent cache entry for \(url)")
        }

        entry["lastAccessedAt"] = lastAccessedAt
        entries[entryID] = entry
        index["entries"] = entries

        let indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
        try data.write(to: indexURL, options: .atomic)
    }

    private func indexObject(in directory: URL) throws -> [String: Any] {
        let indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
        let data = try Data(contentsOf: indexURL)
        guard let index = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw testFixtureError("Persistent cache index is not a JSON object")
        }
        return index
    }

    private func testFixtureError(_ message: String) -> NSError {
        NSError(domain: "PersistentResponseCacheTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class ProtectionWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [String: [FileProtectionType]] = [:]

    func record(_ protectionType: FileProtectionType, path: String) {
        lock.lock()
        writes[path, default: []].append(protectionType)
        lock.unlock()
    }

    func protectionWrites(for path: String) -> [FileProtectionType] {
        lock.lock()
        let pathWrites = writes[path] ?? []
        lock.unlock()
        return pathWrites
    }
}

private final class RecordingFileManager: FileManager, @unchecked Sendable {
    private let recorder: ProtectionWriteRecorder

    init(recorder: ProtectionWriteRecorder) {
        self.recorder = recorder
        super.init()
    }

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if let protectionType = attributes[.protectionKey] as? FileProtectionType {
            recorder.record(protectionType, path: path)
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}
