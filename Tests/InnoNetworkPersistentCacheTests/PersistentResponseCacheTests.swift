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


@Suite("Persistent Response Cache Tests")
struct PersistentResponseCacheTests {
    private static let authenticatedCacheHeaders = ["Cache-Control": "public, max-age=60"]

    @Test("Cache persists entries across actor instances")
    func persistsAcrossInstances() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/user")
        let response = CachedResponse(data: Data("cached".utf8), headers: ["ETag": "v1"])

        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, response)
        let bodyFileName = try #require(existingBodyURLs(in: directory).first?.lastPathComponent)
        #expect(
            (try? PersistentResponseCache.validatedBodyURL(
                fileName: bodyFileName,
                in: directory.appendingPathComponent("bodies", isDirectory: true)
            )) != nil
        )

        let reader = try PersistentResponseCache(configuration: configuration)
        let cached = try #require(await reader.get(key))

        #expect(cached.data == response.data)
        #expect(cached.headers["ETag"] == "v1")
    }

    @Test("Target URI invalidation removes all variants and persists across reopen")
    func invalidateTargetURIRemovesVariantsAcrossReopen() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let first = ResponseCacheKey(
            method: "GET",
            url: "HTTPS://EXAMPLE.COM/items?b=2&a=1#first",
            headers: ["Accept-Language": "en-US"]
        )
        let second = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/items?b=2&a=1#second",
            headers: ["Accept-Language": "ko-KR"]
        )
        let third = ResponseCacheKey(
            method: "HEAD",
            url: "https://example.com/items?b=2&a=1",
            headers: ["X-Variant": "metadata"]
        )
        let other = ResponseCacheKey(method: "GET", url: "https://example.com/items?a=1&b=3")
        let cache = try PersistentResponseCache(configuration: configuration)

        await cache.set(first, CachedResponse(data: Data("first".utf8)))
        await cache.set(second, CachedResponse(data: Data("second".utf8)))
        await cache.set(third, CachedResponse(data: Data("third".utf8)))
        await cache.set(other, CachedResponse(data: Data("other".utf8)))

        await cache.invalidateTargetURI("https://EXAMPLE.com/items?b=2&a=1#latest")

        #expect(await cache.get(first) == nil)
        #expect(await cache.get(second) == nil)
        #expect(await cache.get(third) == nil)
        #expect(await cache.get(other)?.data == Data("other".utf8))

        let reopened = try PersistentResponseCache(configuration: configuration)
        #expect(await reopened.get(first) == nil)
        #expect(await reopened.get(second) == nil)
        #expect(await reopened.get(third) == nil)
        #expect(await reopened.get(other)?.data == Data("other".utf8))
    }

    @Test("Query order remains distinct across persistent-cache reopen")
    func queryOrderRemainsDistinctAcrossReopen() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let first = ResponseCacheKey(method: "GET", url: "https://example.com/items?a=1&b=2")
        let second = ResponseCacheKey(method: "GET", url: "https://example.com/items?b=2&a=1")

        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(first, CachedResponse(data: Data("first".utf8)))
        await writer.set(second, CachedResponse(data: Data("second".utf8)))

        let reader = try PersistentResponseCache(configuration: configuration)
        #expect(await reader.get(first)?.data == Data("first".utf8))
        #expect(await reader.get(second)?.data == Data("second".utf8))
    }

    @Test("Same key with different Vary snapshots stores distinct persistent variants")
    func sameKeyDifferentVarySnapshotsDoNotOverwrite() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/negotiated",
            headers: [
                "Accept": "application/json",
                "Accept-Language": "en-US",
            ]
        )
        let cache = try PersistentResponseCache(configuration: configuration)

        await cache.set(
            key,
            CachedResponse(
                data: Data("language".utf8),
                headers: ["Vary": "Accept-Language"],
                varyHeaders: ["accept-language": "ko-KR"]
            )
        )
        await cache.set(
            key,
            CachedResponse(
                data: Data("accept".utf8),
                headers: ["Vary": "Accept"],
                varyHeaders: ["accept": "application/json"]
            )
        )

        #expect(await cache.statistics().entryCount == 2)
        #expect(await cache.get(key)?.data == Data("accept".utf8))

        await cache.set(
            key,
            CachedResponse(
                data: Data("accept-v2".utf8),
                headers: ["Vary": "Accept"],
                varyHeaders: ["accept": "application/json"]
            )
        )
        #expect(await cache.statistics().entryCount == 2)
        #expect(await cache.get(key)?.data == Data("accept-v2".utf8))

        let reopened = try PersistentResponseCache(configuration: configuration)
        #expect(await reopened.statistics().entryCount == 2)
        #expect(await reopened.get(key)?.data == Data("accept-v2".utf8))

        await reopened.invalidate(key)
        #expect(await reopened.statistics().entryCount == 0)
    }

    @Test("Authorization Vary lookup stays scoped by the HMAC disk key")
    func authorizationVaryLookupRequiresSamePersistentDiskKey() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(
            directoryURL: directory,
            storesAuthenticatedResponses: true
        )
        let firstKey = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Authorization": "Bearer first"]
        )
        let secondKey = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Authorization": "Bearer second"]
        )
        var headers = Self.authenticatedCacheHeaders
        headers["Vary"] = "Authorization"
        let legacySHA256Fingerprint = "sha256:\(String(repeating: "0", count: 64))"
        let cache = try PersistentResponseCache(configuration: configuration)

        await cache.set(
            firstKey,
            CachedResponse(
                data: Data("first".utf8),
                headers: headers,
                varyHeaders: ["authorization": legacySHA256Fingerprint]
            )
        )

        #expect(await cache.get(firstKey)?.data == Data("first".utf8))
        #expect(await cache.get(secondKey) == nil)

        let reopened = try PersistentResponseCache(configuration: configuration)
        #expect(await reopened.get(firstKey)?.data == Data("first".utf8))
        #expect(await reopened.get(secondKey) == nil)
    }

    @Test("Persistent multi-token Vary lookup matches core token-set parity")
    func persistentMultiTokenVaryLookupMatchesCoreTokenSetParity() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/compressed",
            headers: ["Accept-Encoding": "deflate, gzip"]
        )
        let cached = CachedResponse(
            data: Data("compressed".utf8),
            headers: ["Vary": "Accept-Encoding"],
            varyHeaders: ["accept-encoding": "gzip, deflate"]
        )
        var request = URLRequest(url: URL(string: "https://example.com/compressed")!)
        request.setValue("deflate, gzip", forHTTPHeaderField: "Accept-Encoding")
        let cache = try PersistentResponseCache(configuration: configuration)

        #expect(cachedResponseMatchesVary(cached, request: request))

        await cache.set(key, cached)

        #expect(await cache.get(key)?.data == Data("compressed".utf8))

        let reopened = try PersistentResponseCache(configuration: configuration)
        #expect(await reopened.get(key)?.data == Data("compressed".utf8))
    }

    @Test("RFC 9111 compliant policy reads heuristic-fresh persistent entries end to end")
    func rfc9111CompliantPolicyReadsHeuristicFreshPersistentEntry() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/users/1",
            headers: ["Accept-Language": "en-US"]
        )
        let body = try JSONEncoder().encode(PersistentCacheUser(id: 1, name: "cached"))
        await cache.set(
            key,
            CachedResponse(
                data: body,
                headers: ["Last-Modified": "Thu, 01 Jan 1970 00:00:00 GMT"],
                storedAt: Date()
            )
        )
        let session = FailingPersistentCacheURLSession()
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "https://example.com")!,
                responseCachePolicy: .rfc9111Compliant(wrapping: .cacheFirst(maxAge: .seconds(48 * 60 * 60))),
                responseCache: cache,
                acceptLanguageProvider: { "en-US" }
            ),
            session: session
        )

        let user = try await client.request(
            EndpointBuilder<PersistentCacheUser>(method: .get, path: "/users/1")
        )

        #expect(user == PersistentCacheUser(id: 1, name: "cached"))
        #expect(await session.requestCount == 0)
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

    @Test("Authenticated responses require RFC 9111 storage permission even when opt-in is enabled")
    func authenticatedResponsesRequireStoragePermission() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                storesAuthenticatedResponses: true
            )
        )
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Authorization": "Bearer secret"]
        )

        await cache.set(key, CachedResponse(data: Data("private".utf8)))

        #expect(await cache.get(key) == nil)
    }

    @Test(
        "Authenticated responses store with RFC 9111 permission directives",
        arguments: ["public", "must-revalidate", "s-maxage=60"])
    func authenticatedResponsesStoreWithPermissionDirective(cacheControl: String) async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                storesAuthenticatedResponses: true
            )
        )
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Authorization": "Bearer secret"]
        )

        await cache.set(
            key,
            CachedResponse(data: Data("private".utf8), headers: ["Cache-Control": cacheControl])
        )

        #expect(await cache.get(key)?.data == Data("private".utf8))
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

    @Test("Sensitive request header detection trims field-name whitespace")
    func sensitiveRequestHeaderDetectionTrimsFieldNameWhitespace() {
        #expect(
            PersistentResponseCache.containsSensitiveRequestHeader([
                " Authorization \t: Bearer secret"
            ])
        )
    }

    @Test("Authenticated persistent keys are HMAC protected on disk")
    func authenticatedPersistentKeysAreHMACProtectedOnDisk() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(
            directoryURL: directory,
            storesAuthenticatedResponses: true
        )
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Authorization": "Bearer low-entropy-secret"]
        )
        let cache = try PersistentResponseCache(configuration: configuration)

        await cache.set(key, CachedResponse(data: Data("private".utf8), headers: Self.authenticatedCacheHeaders))

        let cached = try #require(await cache.get(key))
        #expect(cached.data == Data("private".utf8))
        let indexText = try String(contentsOf: indexURL(in: directory), encoding: .utf8)
        #expect(!indexText.contains("Bearer low-entropy-secret"))
        #expect(!indexText.contains("authorization:sha256:"))
        #expect(indexText.contains("hmac-sha256:"))
        #expect(FileManager.default.fileExists(atPath: hmacKeyURL(in: directory).path))
    }

    @Test("Persistent cache key normalizer trims optional header whitespace")
    func persistentCacheKeyNormalizerTrimsOptionalHeaderWhitespace() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try PersistentCacheDiskKeyNormalizer.loadOrCreate(
            directoryURL: directory,
            dataProtectionClass: .completeUnlessOpen,
            fileManager: .default
        )

        #expect(
            result.normalizer.normalizeHeaders(["Accept-Language:ko"])
                == result.normalizer.normalizeHeaders(["Accept-Language: ko"])
        )
        #expect(
            result.normalizer.normalizeHeaders(["Authorization:Bearer token"])
                == result.normalizer.normalizeHeaders(["Authorization: Bearer token"])
        )
    }

    @Test("Zero-byte HMAC key file self-heals on reopen")
    func zeroByteHMACKeyFileSelfHealsOnReopen() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(
            directoryURL: directory,
            storesAuthenticatedResponses: true
        )
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Authorization": "Bearer secret"]
        )
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: Data("first".utf8), headers: Self.authenticatedCacheHeaders))

        // Truncate the on-disk HMAC key. Existing entries are now keyed under
        // a key the cache will no longer recognize.
        try Data().write(to: hmacKeyURL(in: directory), options: .atomic)

        let reader = try PersistentResponseCache(configuration: configuration)
        // Prior entry is gone (cache reset together with the key).
        #expect(await reader.get(key) == nil)

        // New writes work end to end.
        await reader.set(key, CachedResponse(data: Data("second".utf8), headers: Self.authenticatedCacheHeaders))
        let cached = try #require(await reader.get(key))
        #expect(cached.data == Data("second".utf8))

        // Key file is regenerated to the expected size.
        let regeneratedKey = try Data(contentsOf: hmacKeyURL(in: directory))
        #expect(regeneratedKey.count == 32)
    }

    @Test("Wrong-length HMAC key file self-heals on reopen")
    func wrongLengthHMACKeyFileSelfHealsOnReopen() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(
            directoryURL: directory,
            storesAuthenticatedResponses: true
        )
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Authorization": "Bearer secret"]
        )
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: Data("first".utf8), headers: Self.authenticatedCacheHeaders))

        // Replace the HMAC key with a 16-byte payload — wrong length but
        // structurally readable. Self-healing should still kick in.
        try Data(repeating: 0xAB, count: 16).write(to: hmacKeyURL(in: directory), options: .atomic)

        let reader = try PersistentResponseCache(configuration: configuration)
        #expect(await reader.get(key) == nil)
        await reader.set(key, CachedResponse(data: Data("second".utf8), headers: Self.authenticatedCacheHeaders))
        let cached = try #require(await reader.get(key))
        #expect(cached.data == Data("second".utf8))
        let regeneratedKey = try Data(contentsOf: hmacKeyURL(in: directory))
        #expect(regeneratedKey.count == 32)
    }

    @Test("Transient HMAC key read failure preserves the key, index, and bodies")
    func transientHMACKeyReadFailurePreservesCacheFiles() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(
            directoryURL: directory,
            storesAuthenticatedResponses: true
        )
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Authorization": "Bearer secret"]
        )
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: Data("first".utf8), headers: Self.authenticatedCacheHeaders))

        let keyURL = hmacKeyURL(in: directory)
        let originalKey = try Data(contentsOf: keyURL)
        let originalIndex = try Data(contentsOf: indexURL(in: directory))
        let originalBodies = try bodySnapshots(in: directory)
        #expect(originalBodies.isEmpty == false)

        do {
            _ = try PersistentCacheDiskKeyNormalizer.loadOrCreate(
                directoryURL: directory,
                dataProtectionClass: configuration.dataProtectionClass,
                fileManager: .default,
                keyFileReader: { _ in
                    throw CocoaError(.fileReadNoPermission)
                }
            )
            Issue.record("Expected the transient key read error to be surfaced")
        } catch let error as CocoaError {
            #expect(error.code == .fileReadNoPermission)
        } catch {
            Issue.record("Expected CocoaError.fileReadNoPermission, got \(error)")
        }

        #expect(try Data(contentsOf: keyURL) == originalKey)
        #expect(try Data(contentsOf: indexURL(in: directory)) == originalIndex)
        #expect(try bodySnapshots(in: directory) == originalBodies)
    }

    @Test("Transient index read failure preserves the key, index, and bodies")
    func transientIndexReadFailurePreservesCacheFiles() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/index-unavailable")
        let payload = Data("cached-index".utf8)
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: payload))

        let keyURL = hmacKeyURL(in: directory)
        let originalKey = try Data(contentsOf: keyURL)
        let originalIndex = try Data(contentsOf: indexURL(in: directory))
        let originalBodies = try bodySnapshots(in: directory)

        let storageIO = PersistentResponseCache.StorageIO(
            indexReader: { _ in
                throw CocoaError(.fileReadNoPermission)
            }
        )
        do {
            _ = try PersistentResponseCache(
                configuration: configuration,
                fileManager: .default,
                storageIO: storageIO
            )
            Issue.record("Expected the transient index read failure to be surfaced")
        } catch let error as CocoaError {
            #expect(error.code == .fileReadNoPermission)
        } catch {
            Issue.record("Expected CocoaError.fileReadNoPermission, got \(error)")
        }

        #expect(try Data(contentsOf: keyURL) == originalKey)
        #expect(try Data(contentsOf: indexURL(in: directory)) == originalIndex)
        #expect(try bodySnapshots(in: directory) == originalBodies)

        let reopened = try PersistentResponseCache(configuration: configuration)
        #expect(await reopened.get(key)?.data == payload)
    }

    @Test("An oversized index cold-resets cache-owned state with a bounded read")
    func oversizedIndexColdResetsCacheOwnedState() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/oversized-index")
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: Data("cached".utf8)))
        #expect(try existingBodyURLs(in: directory).isEmpty == false)

        let handle = try FileHandle(forWritingTo: indexURL(in: directory))
        try handle.truncate(
            atOffset: UInt64(PersistentResponseCache.maximumIndexByteCount + 1)
        )
        try handle.close()

        let reopened = try PersistentResponseCache(configuration: configuration)

        #expect(await reopened.statistics().entryCount == 0)
        #expect(try existingBodyURLs(in: directory).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: indexURL(in: directory).path))
    }

    @Test("A missing index is the only index read failure treated as an empty cache")
    func missingIndexReadStartsEmptyCache() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        #expect(PersistentResponseCache.isMissingFileError(CocoaError(.fileNoSuchFile)))
        #expect(PersistentResponseCache.isMissingFileError(CocoaError(.fileReadNoSuchFile)))
        #expect(!PersistentResponseCache.isMissingFileError(CocoaError(.fileReadNoPermission)))
        let storageIO = PersistentResponseCache.StorageIO(
            indexReader: { _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            }
        )

        let cache = try PersistentResponseCache(
            configuration: configuration,
            fileManager: .default,
            storageIO: storageIO
        )

        #expect(await cache.statistics().entryCount == 0)
        #expect(try existingBodyURLs(in: directory).isEmpty)
    }

    @Test("The default live reader opens an existing cache directory with no index")
    func defaultLiveMissingIndexStartsEmptyCache() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let first = try PersistentResponseCache(configuration: configuration)
        #expect(await first.statistics().entryCount == 0)
        #expect(!FileManager.default.fileExists(atPath: indexURL(in: directory).path))

        let reopened = try PersistentResponseCache(configuration: configuration)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/live-missing-index")
        let payload = Data("created-after-missing-index".utf8)
        await reopened.set(key, CachedResponse(data: payload))

        #expect(await reopened.get(key)?.data == payload)
    }

    @Test("A directory at the index path cold-resets cache-owned state")
    func indexDirectoryColdResets() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/index-directory")
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: Data("cached".utf8)))
        #expect(try existingBodyURLs(in: directory).count == 1)

        let index = indexURL(in: directory)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)

        let reopened = try PersistentResponseCache(configuration: configuration)

        #expect(await reopened.statistics().entryCount == 0)
        #expect(try existingBodyURLs(in: directory).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: index.path))
    }

    @Test("An index symlink cold-resets owned state without reading its target")
    func indexSymlinkNeverReadsOutsideTarget() async throws {
        let directory = makeDirectory()
        let outsideDirectory = makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/index-symlink")
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: Data("cached".utf8)))

        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: true
        )
        let outsideIndex = outsideDirectory.appendingPathComponent("outside-index.json")
        let outsideData = Data("outside-sentinel".utf8)
        try outsideData.write(to: outsideIndex)
        let index = indexURL(in: directory)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createSymbolicLink(at: index, withDestinationURL: outsideIndex)

        let reopened = try PersistentResponseCache(configuration: configuration)

        #expect(await reopened.statistics().entryCount == 0)
        #expect(try existingBodyURLs(in: directory).isEmpty)
        #expect(try Data(contentsOf: outsideIndex) == outsideData)
    }

    @Test("A FIFO body is rejected without waiting for a writer")
    func fifoBodyCannotBlockCacheOpen() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/body-fifo")
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: Data("cached".utf8)))
        let bodyURL = try #require(existingBodyURLs(in: directory).first)
        try FileManager.default.removeItem(at: bodyURL)
        #expect(mkfifo(bodyURL.path, S_IRUSR | S_IWUSR) == 0)

        let openTask = Task.detached {
            try? PersistentResponseCache(configuration: configuration)
        }
        let completedBeforeTimeout = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await openTask.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(250))
                return false
            }
            let completed = await group.next() ?? false
            if !completed {
                // Unblock a regressed implementation so the test itself
                // remains bounded even if O_NONBLOCK is accidentally removed.
                let peer = open(bodyURL.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
                if peer >= 0 { close(peer) }
            }
            group.cancelAll()
            return completed
        }
        let reopened = try #require(await openTask.value)

        #expect(completedBeforeTimeout)
        #expect(await reopened.statistics().entryCount == 0)
    }

    @Test("Transient open-time body inspection failure preserves cache files")
    func transientBodyInspectionFailurePreservesCacheFiles() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/body-inspection-unavailable")
        let payload = Data("cached-body".utf8)
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: payload))

        let originalIndex = try Data(contentsOf: indexURL(in: directory))
        let originalBodies = try bodySnapshots(in: directory)
        let storageIO = PersistentResponseCache.StorageIO(
            bodyInspector: { _, _ in
                throw PersistentResponseCache.BodyFileAccessError.cannotInspectFile(errno: EIO)
            }
        )

        do {
            _ = try PersistentResponseCache(
                configuration: configuration,
                fileManager: .default,
                storageIO: storageIO
            )
            Issue.record("Expected the transient body inspection failure to be surfaced")
        } catch let error as PersistentResponseCache.BodyFileAccessError {
            #expect(error == .cannotInspectFile(errno: EIO))
        } catch {
            Issue.record("Expected a body inspection EIO, got \(error)")
        }

        #expect(try Data(contentsOf: indexURL(in: directory)) == originalIndex)
        #expect(try bodySnapshots(in: directory) == originalBodies)

        let reopened = try PersistentResponseCache(configuration: configuration)
        #expect(await reopened.get(key)?.data == payload)
    }

    @Test("Transient get body read failure preserves the entry for retry")
    func transientBodyReadFailurePreservesEntryForRetry() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/body-read-unavailable")
        let payload = Data("retry-body".utf8)
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: payload))

        let originalIndex = try Data(contentsOf: indexURL(in: directory))
        let originalBodies = try bodySnapshots(in: directory)
        let transientReader = TransientPersistentCacheBodyReader()
        let storageIO = PersistentResponseCache.StorageIO(
            bodyReader: { fileName, directoryURL, maximumByteCount in
                try await transientReader.read(
                    fileName: fileName,
                    in: directoryURL,
                    maximumByteCount: maximumByteCount
                )
            }
        )
        let cache = try PersistentResponseCache(
            configuration: configuration,
            fileManager: .default,
            storageIO: storageIO
        )
        let priorEvictionCount = await cache.statistics().evictionCount

        #expect(await cache.get(key) == nil)
        #expect(await cache.statistics().entryCount == 1)
        #expect(await cache.statistics().evictionCount == priorEvictionCount)
        #expect(
            await cache.telemetrySnapshot()
                .contains(.scrubbedEntries(reason: .missingBody, count: 1, byteCount: payload.count)) == false
        )
        #expect(try Data(contentsOf: indexURL(in: directory)) == originalIndex)
        #expect(try bodySnapshots(in: directory) == originalBodies)

        #expect(await cache.get(key)?.data == payload)
        #expect(await transientReader.attemptCount == 2)
    }

    #if canImport(Security)
    @Test(
        "Transient Keychain read statuses preserve the item and cache files",
        arguments: [
            errSecInteractionNotAllowed,
            errSecNotAvailable,
            errSecMissingEntitlement,
        ])
    func transientKeychainReadStatusPreservesState(status: OSStatus) throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bodiesURL = directory.appendingPathComponent("bodies", isDirectory: true)
        try FileManager.default.createDirectory(at: bodiesURL, withIntermediateDirectories: true)
        let originalIndex = Data("existing-index".utf8)
        let originalBody = Data("existing-body".utf8)
        try originalIndex.write(to: indexURL(in: directory), options: .atomic)
        let bodyURL = bodiesURL.appendingPathComponent("existing.body", isDirectory: false)
        try originalBody.write(to: bodyURL, options: .atomic)
        let keychain = StubPersistentCacheKeychain(copyStatus: status)

        do {
            _ = try PersistentCacheDiskKeyNormalizer.loadOrCreateFromKeychain(
                directoryURL: directory,
                service: "com.innosquad.InnoNetwork.tests",
                accessGroup: nil,
                fileManager: .default,
                keychainOperations: keychain.operations
            )
            Issue.record("Expected Keychain read status \(status) to be surfaced")
        } catch NetworkError.configuration(reason: .invalidRequest(let message)) {
            #expect(message.contains("status: \(status)"))
        } catch {
            Issue.record("Expected a Keychain configuration error, got \(error)")
        }

        #expect(keychain.copyCallCount == 1)
        #expect(keychain.deleteCallCount == 0)
        #expect(keychain.addCallCount == 0)
        #expect(try Data(contentsOf: indexURL(in: directory)) == originalIndex)
        #expect(try Data(contentsOf: bodyURL) == originalBody)
    }

    @Test("A successfully read wrong-length Keychain key is regenerated")
    func wrongLengthKeychainKeyRegenerates() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keychain = StubPersistentCacheKeychain(
            copyStatus: errSecSuccess,
            copiedData: Data(repeating: 0xAB, count: 16)
        )

        let result = try PersistentCacheDiskKeyNormalizer.loadOrCreateFromKeychain(
            directoryURL: directory,
            service: "com.innosquad.InnoNetwork.tests",
            accessGroup: nil,
            fileManager: .default,
            keychainOperations: keychain.operations
        )

        #expect(result.regenerated)
        #expect(keychain.copyCallCount == 1)
        #expect(keychain.deleteCallCount == 1)
        #expect(keychain.addCallCount == 1)
        #expect(keychain.addedKeyData?.count == 32)
    }

    @Test("A missing Keychain item creates a key without deleting")
    func missingKeychainItemCreatesWithoutDelete() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keychain = StubPersistentCacheKeychain(copyStatus: errSecItemNotFound)

        let result = try PersistentCacheDiskKeyNormalizer.loadOrCreateFromKeychain(
            directoryURL: directory,
            service: "com.innosquad.InnoNetwork.tests",
            accessGroup: nil,
            fileManager: .default,
            keychainOperations: keychain.operations
        )

        #expect(!result.regenerated)
        #expect(keychain.copyCallCount == 1)
        #expect(keychain.deleteCallCount == 0)
        #expect(keychain.addCallCount == 1)
        #expect(keychain.addedKeyData?.count == 32)
    }
    #endif

    @Test("Non-regular HMAC key path still self-heals as structural corruption")
    func nonRegularHMACKeyPathSelfHeals() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(
            directoryURL: directory,
            maxBytes: 1_000_000
        )
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/non-regular-key")
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: Data("first".utf8), headers: Self.authenticatedCacheHeaders))

        let keyURL = hmacKeyURL(in: directory)
        try FileManager.default.removeItem(at: keyURL)
        try FileManager.default.createDirectory(at: keyURL, withIntermediateDirectories: false)

        let reader = try PersistentResponseCache(configuration: configuration)
        #expect(await reader.get(key) == nil)
        let regeneratedKey = try Data(contentsOf: keyURL)
        #expect(regeneratedKey.count == 32)
    }

    @Test("Missing HMAC key with existing entries resets index and bodies")
    func missingHMACKeyWithExistingEntriesResetsCacheOnReopen() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(
            directoryURL: directory,
            storesAuthenticatedResponses: true
        )
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Authorization": "Bearer secret"]
        )
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: Data("first".utf8), headers: Self.authenticatedCacheHeaders))
        #expect(try existingBodyURLs(in: directory).isEmpty == false)

        try FileManager.default.removeItem(at: hmacKeyURL(in: directory))

        let reader = try PersistentResponseCache(configuration: configuration)

        #expect(await reader.get(key) == nil)
        #expect(try existingBodyURLs(in: directory).isEmpty)
        #expect(await reader.statistics().entryCount == 0)
        let regeneratedKey = try Data(contentsOf: hmacKeyURL(in: directory))
        #expect(regeneratedKey.count == 32)
    }

    @Test("Fresh cache directory key creation is not counted as eviction")
    func freshCacheDirectoryKeyCreationIsNotCountedAsEviction() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )

        #expect(await cache.statistics().evictionCount == 0)
        #expect(await cache.telemetrySnapshot().isEmpty)
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

        let scrubber = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        #expect(try existingBodyURLs(in: directory).isEmpty)
        #expect(try indexEntryCount(in: directory) == 0)
        #expect(
            await scrubber.drainTelemetryEvents()
                .contains(.scrubbedEntries(reason: .policyRejected, count: 1, byteCount: 6))
        )

        let reopened = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                storesAuthenticatedResponses: true
            )
        )
        #expect(await reopened.get(key) == nil)
    }

    @Test("Opt-in policy scrubs legacy Authorization entries without RFC 9111 permission on open")
    func optInPolicyScrubsAuthorizedEntriesWithoutStoragePermissionOnOpen() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Authorization": "Bearer secret"]
        )
        let configuration = PersistentResponseCacheConfiguration(
            directoryURL: directory,
            storesAuthenticatedResponses: true
        )
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: Data("legacy".utf8), headers: Self.authenticatedCacheHeaders))
        #expect(await writer.get(key) != nil)
        #expect(try existingBodyURLs(in: directory).isEmpty == false)

        try rewriteFirstIndexEntryHeaders(in: directory, headers: ["ETag": "legacy"])

        _ = try PersistentResponseCache(configuration: configuration)

        #expect(try existingBodyURLs(in: directory).isEmpty)
        #expect(try indexEntryCount(in: directory) == 0)
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

    @Test("Version 2 index cold-resets after query-order key change")
    func versionTwoIndexColdResets() async throws {
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
        index["version"] = 2
        let indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
        let legacyIndexData = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
        try legacyIndexData.write(to: indexURL, options: .atomic)

        let reopened = try PersistentResponseCache(configuration: configuration)
        #expect(await reopened.get(legacyKey) == nil)
        #expect(try existingBodyURLs(in: directory).isEmpty)

        let newKey = ResponseCacheKey(method: "GET", url: "https://example.com/recovered")
        await reopened.set(newKey, CachedResponse(data: Data("new".utf8)))
        #expect(try indexObject(in: directory)["version"] as? Int == 3)
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

        let recorder = ProtectionWriteRecorder()
        let fileManager = RecordingFileManager(recorder: recorder)
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

        let recorder = ProtectionWriteRecorder()
        let fileManager = RecordingFileManager(recorder: recorder)
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

    private func bodySnapshots(in directory: URL) throws -> [String: Data] {
        try Dictionary(
            uniqueKeysWithValues: existingBodyURLs(in: directory).map { url in
                (url.lastPathComponent, try Data(contentsOf: url))
            }
        )
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

    private func rewriteFirstIndexEntryBodyFileName(
        in directory: URL,
        bodyFileName: String
    ) throws {
        var index = try indexObject(in: directory)
        guard var entries = index["entries"] as? [String: Any],
            let entryID = entries.keys.sorted().first,
            var entry = entries[entryID] as? [String: Any]
        else {
            throw testFixtureError("Missing persistent cache entry to rewrite")
        }

        entry["bodyFileName"] = bodyFileName
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
        let data = try Data(contentsOf: indexURL(in: directory))
        guard let index = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw testFixtureError("Persistent cache index is not a JSON object")
        }
        return index
    }

    private func indexURL(in directory: URL) -> URL {
        directory.appendingPathComponent("index.json", isDirectory: false)
    }

    private func hmacKeyURL(in directory: URL) -> URL {
        directory.appendingPathComponent("cache-key-hmac.key", isDirectory: false)
    }

    private func backupExclusionIsApplied(to url: URL) throws -> Bool {
        #if os(macOS)
        // Foundation writes the standard backup-exclusion xattr on macOS but
        // `resourceValues` reports `false` because the key is iOS-oriented.
        // Query the xattr directly because `attributesOfItem` can briefly
        // return a stale extended-attribute dictionary after `removexattr`.
        let result: (length: Int, errorCode: Int32) = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return (-1, EINVAL) }
            return "com.apple.metadata:com_apple_backup_excludeItem".withCString { name in
                let length = getxattr(path, name, nil, 0, 0, 0)
                return (length, length < 0 ? errno : 0)
            }
        }
        if result.length >= 0 {
            return true
        }
        if result.errorCode == ENOATTR {
            return false
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(result.errorCode))
        #else
        return try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
        #endif
    }

    private func removeBackupExclusion(from url: URL) throws {
        #if os(macOS)
        // Foundation's metadata write can settle just after `setResourceValues`
        // returns on a contended hosted runner. Establish a stable absent
        // precondition instead of racing that write with a single removexattr.
        var consecutiveAbsentObservations = 0
        for attempt in 0..<10 {
            let result: (status: Int32, errorCode: Int32) = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return (-1, EINVAL) }
                return "com.apple.metadata:com_apple_backup_excludeItem".withCString { name in
                    let status = removexattr(path, name, 0)
                    return (status, status == 0 ? 0 : errno)
                }
            }
            if result.status != 0, result.errorCode != ENOATTR {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(result.errorCode))
            }
            if try backupExclusionIsApplied(to: url) == false {
                consecutiveAbsentObservations += 1
                if consecutiveAbsentObservations == 2 {
                    return
                }
            } else {
                consecutiveAbsentObservations = 0
            }
            if attempt < 9 {
                usleep(5_000)
            }
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
        #else
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try resourceURL.setResourceValues(values)
        #endif
    }

    private func createHardLink(from sourceURL: URL, to destinationURL: URL) throws {
        let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return link(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func testFixtureError(_ message: String) -> NSError {
        NSError(domain: "PersistentResponseCacheTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

#if canImport(Security)
private final class StubPersistentCacheKeychain {
    private let copyStatus: OSStatus
    private let copiedData: Data?
    private let deleteStatus: OSStatus
    private let addStatus: OSStatus

    private(set) var copyCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var addCallCount = 0
    private(set) var addedKeyData: Data?

    init(
        copyStatus: OSStatus,
        copiedData: Data? = nil,
        deleteStatus: OSStatus = errSecSuccess,
        addStatus: OSStatus = errSecSuccess
    ) {
        self.copyStatus = copyStatus
        self.copiedData = copiedData
        self.deleteStatus = deleteStatus
        self.addStatus = addStatus
    }

    var operations: PersistentCacheKeychainOperations {
        PersistentCacheKeychainOperations(
            copyMatching: { _ in
                self.copyCallCount += 1
                return (self.copyStatus, self.copiedData)
            },
            delete: { _ in
                self.deleteCallCount += 1
                return self.deleteStatus
            },
            add: { attributes in
                self.addCallCount += 1
                self.addedKeyData = attributes[kSecValueData as String] as? Data
                return self.addStatus
            }
        )
    }
}
#endif

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

private actor TransientPersistentCacheBodyReader {
    private(set) var attemptCount = 0

    func read(
        fileName: String,
        in directoryURL: URL,
        maximumByteCount: Int
    ) async throws -> Data {
        attemptCount += 1
        if attemptCount == 1 {
            throw PersistentResponseCache.BodyFileAccessError.cannotOpenFile(errno: EACCES)
        }
        return try await PersistentResponseCache.readBodyData(
            fileName: fileName,
            in: directoryURL,
            maximumByteCount: maximumByteCount
        )
    }
}

private struct PersistentCacheUser: Codable, Sendable, Equatable {
    let id: Int
    let name: String
}

private actor FailingPersistentCacheURLSessionState {
    private var count = 0

    func record() {
        count += 1
    }

    var requestCount: Int { count }
}

private final class FailingPersistentCacheURLSession: URLSessionProtocol, Sendable {
    private let state = FailingPersistentCacheURLSessionState()

    var requestCount: Int {
        get async { await state.requestCount }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        _ = request
        await state.record()
        throw NetworkError.configuration(reason: .invalidRequest("persistent cache test should not hit transport"))
    }
}
