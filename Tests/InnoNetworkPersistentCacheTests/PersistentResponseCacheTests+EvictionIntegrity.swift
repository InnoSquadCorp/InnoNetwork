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
        #expect(
            await cache.telemetrySnapshot()
                .contains(.scrubbedEntries(reason: .storageBudget, count: 1, byteCount: 24))
        )
        #expect(await cache.drainTelemetryEvents().isEmpty == false)
        #expect(await cache.telemetrySnapshot().isEmpty)
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
        #expect(
            await reopened.drainTelemetryEvents()
                .contains(.scrubbedEntries(reason: .entryTooLarge, count: 1, byteCount: 32))
        )
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

    @Test("Reopen removes unreferenced staged body files")
    func reopenRemovesUnreferencedStagedBodyFiles() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/orphaned-body")
        let writer = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        await writer.set(key, CachedResponse(data: Data("indexed".utf8)))

        let bodiesURL = directory.appendingPathComponent("bodies", isDirectory: true)
        let orphanURL = bodiesURL.appendingPathComponent("\(UUID().uuidString).body", isDirectory: false)
        try Data("orphan".utf8).write(to: orphanURL, options: .atomic)
        #expect(FileManager.default.fileExists(atPath: orphanURL.path))

        let reopened = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )

        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        let cached = try #require(await reopened.get(key))
        #expect(cached.data == Data("indexed".utf8))
        #expect(try existingBodyURLs(in: directory).count == 1)
        #expect(
            await reopened.drainTelemetryEvents()
                .contains(.scrubbedEntries(reason: .unreferencedBody, count: 1, byteCount: 0))
        )
    }

    @Test("Tampered body traversal cannot read or delete a caller-owned file")
    func tamperedBodyTraversalCannotEscapeCacheDirectory() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/traversal")
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: Data("cached".utf8)))

        let sentinelURL = directory.appendingPathComponent("sentinel.txt", isDirectory: false)
        let sentinel = Data("caller-owned".utf8)
        try sentinel.write(to: sentinelURL, options: .atomic)
        PersistentResponseCache.removeBody(
            fileName: "../sentinel.txt",
            in: directory.appendingPathComponent("bodies", isDirectory: true),
            fileManager: .default
        )
        #expect(try Data(contentsOf: sentinelURL) == sentinel)
        try rewriteFirstIndexEntryBodyFileName(in: directory, bodyFileName: "../sentinel.txt")

        let reopened = try PersistentResponseCache(configuration: configuration)

        #expect(await reopened.get(key) == nil)
        await reopened.invalidate(key)
        #expect(try Data(contentsOf: sentinelURL) == sentinel)
        #expect(try indexEntryCount(in: directory) == 0)
    }

    @Test("Reopen rejects a body symlink without reading or deleting its target")
    func reopenRejectsBodySymlinkWithoutFollowingTarget() async throws {
        let directory = makeDirectory()
        let sentinelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("innonetwork-external-sentinel-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: sentinelURL)
        }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/symlink")
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: Data("cached".utf8)))

        let bodyURL = try #require(existingBodyURLs(in: directory).first)
        let sentinel = Data("outside-cache".utf8)
        try sentinel.write(to: sentinelURL, options: .atomic)
        try FileManager.default.removeItem(at: bodyURL)
        try FileManager.default.createSymbolicLink(at: bodyURL, withDestinationURL: sentinelURL)

        let reopened = try PersistentResponseCache(configuration: configuration)

        #expect(await reopened.get(key) == nil)
        #expect(try Data(contentsOf: sentinelURL) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: bodyURL.path))
        #expect(try indexEntryCount(in: directory) == 0)
    }

    @Test("An open cache remains anchored when its visible root is replaced")
    func openCacheIgnoresVisibleRootReplacement() async throws {
        let directory = makeDirectory()
        let anchoredRoot = directory.deletingLastPathComponent()
            .appendingPathComponent("innonetwork-anchored-root-\(UUID().uuidString)", isDirectory: true)
        let outsideDirectory = makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: anchoredRoot)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }

        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let firstKey = ResponseCacheKey(method: "GET", url: "https://example.com/root-before-swap")
        let secondKey = ResponseCacheKey(method: "GET", url: "https://example.com/root-after-swap")
        await cache.set(firstKey, CachedResponse(data: Data("before".utf8)))

        try FileManager.default.moveItem(at: directory, to: anchoredRoot)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let sentinelURL = outsideDirectory.appendingPathComponent("caller-owned.txt")
        let sentinel = Data("outside-root".utf8)
        try sentinel.write(to: sentinelURL)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outsideDirectory)

        await cache.set(secondKey, CachedResponse(data: Data("after".utf8)))

        #expect(await cache.get(firstKey)?.data == Data("before".utf8))
        #expect(await cache.get(secondKey)?.data == Data("after".utf8))
        #expect(try Data(contentsOf: sentinelURL) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: outsideDirectory.appendingPathComponent("index.json").path))
        #expect(try existingBodyURLs(in: anchoredRoot).count == 2)

        await cache.removeAll()

        #expect(try Data(contentsOf: sentinelURL) == sentinel)
        #expect(try existingBodyURLs(in: anchoredRoot).isEmpty)
        #expect(try indexEntryCount(in: anchoredRoot) == 0)
    }

    @Test("An open cache remains anchored when its visible bodies directory is replaced")
    func openCacheIgnoresVisibleBodiesReplacement() async throws {
        let directory = makeDirectory()
        let outsideDirectory = makeDirectory()
        let anchoredBodies = directory.appendingPathComponent("anchored-bodies", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }

        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let firstKey = ResponseCacheKey(method: "GET", url: "https://example.com/bodies-before-swap")
        let secondKey = ResponseCacheKey(method: "GET", url: "https://example.com/bodies-after-swap")
        await cache.set(firstKey, CachedResponse(data: Data("before".utf8)))

        let visibleBodies = directory.appendingPathComponent("bodies", isDirectory: true)
        try FileManager.default.moveItem(at: visibleBodies, to: anchoredBodies)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let sentinelURL = outsideDirectory.appendingPathComponent("caller-owned.txt")
        let sentinel = Data("outside-bodies".utf8)
        try sentinel.write(to: sentinelURL)
        try FileManager.default.createSymbolicLink(at: visibleBodies, withDestinationURL: outsideDirectory)

        await cache.set(secondKey, CachedResponse(data: Data("after".utf8)))

        #expect(await cache.get(firstKey)?.data == Data("before".utf8))
        #expect(await cache.get(secondKey)?.data == Data("after".utf8))
        #expect(try Data(contentsOf: sentinelURL) == sentinel)
        #expect(
            try FileManager.default.contentsOfDirectory(at: outsideDirectory, includingPropertiesForKeys: nil)
                .map(\.lastPathComponent) == ["caller-owned.txt"]
        )

        await cache.removeAll()

        #expect(try Data(contentsOf: sentinelURL) == sentinel)
        #expect(
            try FileManager.default.contentsOfDirectory(at: anchoredBodies, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test("Reopen rejects a hard-linked body without mutating its other link")
    func reopenRejectsHardLinkedBodyWithoutMutatingOutsideFile() async throws {
        let directory = makeDirectory()
        let outsideDirectory = makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/body-hard-link")
        let writer = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        await writer.set(key, CachedResponse(data: Data("cached".utf8)))

        let bodyURL = try #require(existingBodyURLs(in: directory).first)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideURL = outsideDirectory.appendingPathComponent("outside-body.txt")
        let sentinel = Data("outside-hard-link".utf8)
        try sentinel.write(to: outsideURL)
        try FileManager.default.removeItem(at: bodyURL)
        try createHardLink(from: outsideURL, to: bodyURL)

        let reopened = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )

        #expect(await reopened.get(key) == nil)
        #expect(try Data(contentsOf: outsideURL) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: bodyURL.path))
        #expect(try indexEntryCount(in: directory) == 0)
    }

    @Test("Reopen replaces a hard-linked key without mutating its other link")
    func reopenReplacesHardLinkedKeyWithoutMutatingOutsideFile() async throws {
        let directory = makeDirectory()
        let outsideDirectory = makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/key-hard-link")
        let writer = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        await writer.set(key, CachedResponse(data: Data("cached".utf8)))

        let keyURL = hmacKeyURL(in: directory)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideURL = outsideDirectory.appendingPathComponent("outside-key.bin")
        let sentinel = Data(repeating: 0xA5, count: 32)
        try sentinel.write(to: outsideURL)
        try FileManager.default.removeItem(at: keyURL)
        try createHardLink(from: outsideURL, to: keyURL)

        let reopened = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )

        #expect(await reopened.get(key) == nil)
        #expect(try Data(contentsOf: outsideURL) == sentinel)
        #expect(try Data(contentsOf: keyURL) != sentinel)
        #expect(try existingBodyURLs(in: directory).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: indexURL(in: directory).path))
    }

}
