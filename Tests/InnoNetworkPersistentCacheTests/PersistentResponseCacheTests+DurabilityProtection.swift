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

    @Test("PersistentResponseCacheConfiguration defaults to first-unlock protection")
    func defaultDataProtectionClassIsCompleteUntilFirstUserAuthentication() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        #expect(configuration.dataProtectionClass == .completeUntilFirstUserAuthentication)
    }

    #if canImport(Darwin)
    @Test("Cache-owned directories and files are excluded from backup and repaired on reopen")
    func cacheOwnedPathsAreExcludedFromBackup() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/backup-exclusion")

        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: Data("cached".utf8)))

        let bodiesURL = directory.appendingPathComponent("bodies", isDirectory: true)
        let indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
        let keyURL = hmacKeyURL(in: directory)
        let bodyURLs = try existingBodyURLs(in: directory)
        let ownedURLs = [bodiesURL, indexURL, keyURL] + bodyURLs
        for url in ownedURLs {
            #expect(try backupExclusionIsApplied(to: url))
        }
        // `directoryURL` may contain caller-owned sentinels. Exclude each
        // cache-owned path rather than changing backup policy for the root.
        #expect(try backupExclusionIsApplied(to: directory) == false)

        for url in [indexURL, keyURL] + bodyURLs {
            try removeBackupExclusion(from: url)
            #expect(
                try backupExclusionIsApplied(to: url) == false,
                "Backup exclusion setup was not cleared for \(url.path)"
            )
        }

        _ = try PersistentResponseCache(configuration: configuration)

        for url in [indexURL, keyURL] + bodyURLs {
            #expect(
                try backupExclusionIsApplied(to: url),
                "Backup exclusion was not repaired for \(url.path)"
            )
        }
    }

    @Test("Storage protection never follows symbolic links outside the cache")
    func storageProtectionDoesNotFollowSymbolicLinks() throws {
        let directory = makeDirectory()
        let targetURL = directory.appendingPathComponent("caller-owned.txt", isDirectory: false)
        let linkURL = directory.appendingPathComponent("cache-link", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("caller".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        PersistentResponseCache.applyDataProtection(
            .completeUntilFirstUserAuthentication,
            to: linkURL,
            fileManager: .default
        )

        #if canImport(Darwin)
        #expect(try backupExclusionIsApplied(to: targetURL) == false)
        #endif
    }
    #endif

    @Test("Reopen reapplies data protection to existing index, HMAC key, and body files")
    func reopenReappliesDataProtectionToExistingCacheFiles() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/reopen-protection")

        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: Data("protected".utf8)))
        let bodyURLs = try existingBodyURLs(in: directory)
        #expect(bodyURLs.isEmpty == false)

        let recorder = PersistentCacheProtectionWriteRecorder()
        let fileManager = PersistentCacheRecordingFileManager(recorder: recorder)
        _ = try PersistentResponseCache(configuration: configuration, fileManager: fileManager)

        let indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
        let hmacKeyURL = hmacKeyURL(in: directory)
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        #expect(
            recorder.protectionWrites(for: indexURL.path)
                .contains(.completeUntilFirstUserAuthentication)
        )
        #expect(
            recorder.protectionWrites(for: hmacKeyURL.path)
                .contains(.completeUntilFirstUserAuthentication)
        )
        for bodyURL in bodyURLs {
            #expect(
                recorder.protectionWrites(for: bodyURL.path)
                    .contains(.completeUntilFirstUserAuthentication)
            )
        }
        #else
        #expect(recorder.protectionWrites(for: indexURL.path).isEmpty)
        #expect(recorder.protectionWrites(for: hmacKeyURL.path).isEmpty)
        for bodyURL in bodyURLs {
            #expect(recorder.protectionWrites(for: bodyURL.path).isEmpty)
        }
        #endif
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

        let recorder = PersistentCacheProtectionWriteRecorder()
        let fileManager = PersistentCacheRecordingFileManager(recorder: recorder)
        let unprotectedConfiguration = PersistentResponseCacheConfiguration(
            directoryURL: directory,
            dataProtectionClass: .none
        )
        _ = try PersistentResponseCache(configuration: unprotectedConfiguration, fileManager: fileManager)

        let indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
        let bodiesURL = directory.appendingPathComponent("bodies", isDirectory: true)
        let hmacKeyURL = hmacKeyURL(in: directory)
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        #expect(recorder.protectionWrites(for: directory.path).contains(.none))
        #expect(recorder.protectionWrites(for: bodiesURL.path).contains(.none))
        #expect(recorder.protectionWrites(for: indexURL.path).contains(.none))
        #expect(recorder.protectionWrites(for: hmacKeyURL.path).contains(.none))
        for bodyURL in bodyURLs {
            #expect(recorder.protectionWrites(for: bodyURL.path).contains(.none))
        }
        #else
        #expect(recorder.protectionWrites(for: directory.path).isEmpty)
        #expect(recorder.protectionWrites(for: bodiesURL.path).isEmpty)
        #expect(recorder.protectionWrites(for: indexURL.path).isEmpty)
        #expect(recorder.protectionWrites(for: hmacKeyURL.path).isEmpty)
        for bodyURL in bodyURLs {
            #expect(recorder.protectionWrites(for: bodyURL.path).isEmpty)
        }
        #endif
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
}
