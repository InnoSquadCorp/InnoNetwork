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

}
