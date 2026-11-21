import Foundation
import InnoNetwork
import Testing

@testable import InnoNetworkPersistentCache

extension PersistentResponseCacheTests {
    @Test(
        "get() scrubs a same-length body whose bytes changed on disk",
        arguments: [false, true]
    )
    func getScrubsSameLengthBodyWithFlippedByte(reopenBeforeRead: Bool) async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/flipped-byte")
        let payload = Data("integrity-protected-body".utf8)
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: payload))
        let bodyURL = try #require(existingBodyURLs(in: directory).first)

        try flipByteInPlace(at: bodyURL, offset: payload.count / 2)
        let corrupted = try Data(contentsOf: bodyURL)
        #expect(corrupted.count == payload.count)
        #expect(corrupted != payload)

        // Opening only inspects body sizes, so a same-length corruption is
        // still indexed until the first read verifies the bytes.
        let cache = reopenBeforeRead ? try PersistentResponseCache(configuration: configuration) : writer
        let prior = await cache.statistics()
        #expect(prior.entryCount == 1)
        #expect(await cache.telemetrySnapshot().isEmpty)

        #expect(await cache.get(key) == nil)

        try await expectBodyIntegrityScrub(
            in: cache,
            directory: directory,
            prior: prior,
            scrubbedByteCost: payload.count
        )
        try await expectFreshEntryRoundTrips(in: cache, key: key, directory: directory)
    }

    @Test(
        "get() scrubs a truncated body",
        arguments: [0, 1, 23], [false, true]
    )
    func getScrubsTruncatedBody(remainingByteCount: Int, reopenBeforeRead: Bool) async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/truncated-body")
        let payload = Data("integrity-protected-body".utf8)
        #expect(payload.count == 24)
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: payload))
        let bodyURL = try #require(existingBodyURLs(in: directory).first)

        try resizeInPlace(bodyURL, toByteCount: remainingByteCount)
        #expect(try Data(contentsOf: bodyURL) == payload.prefix(remainingByteCount))

        if reopenBeforeRead {
            // Opening compares each body file's length with the recorded
            // byte count, so the truncated body never reaches the index.
            let cache = try PersistentResponseCache(configuration: configuration)
            try await expectOpenTimeLengthScrub(in: cache, directory: directory, scrubbedByteCost: payload.count)
            #expect(await cache.get(key) == nil)
            try await expectFreshEntryRoundTrips(in: cache, key: key, directory: directory)
            return
        }

        // An open cache verifies the body when it is read.
        let prior = await writer.statistics()
        #expect(prior.entryCount == 1)
        #expect(prior.byteCount == payload.count)
        #expect(await writer.telemetrySnapshot().isEmpty)

        #expect(await writer.get(key) == nil)

        try await expectBodyIntegrityScrub(
            in: writer,
            directory: directory,
            prior: prior,
            scrubbedByteCost: payload.count
        )
        try await expectFreshEntryRoundTrips(in: writer, key: key, directory: directory)
    }

    @Test("get() scrubs a body that grew but still fits maxEntryBytes")
    func getScrubsBodyExtendedWithinEntryLimit() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/extended-body")
        let payload = Data("integrity-protected-body".utf8)
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                maxEntryBytes: 64
            )
        )
        await cache.set(key, CachedResponse(data: payload))
        let bodyURL = try #require(existingBodyURLs(in: directory).first)

        try resizeInPlace(bodyURL, toByteCount: payload.count + 1)
        #expect(try Data(contentsOf: bodyURL) == payload + Data([0]))
        let prior = await cache.statistics()

        #expect(await cache.get(key) == nil)

        try await expectBodyIntegrityScrub(
            in: cache,
            directory: directory,
            prior: prior,
            scrubbedByteCost: payload.count
        )
        try await expectFreshEntryRoundTrips(in: cache, key: key, directory: directory)
    }

    @Test(
        "An untouched body round-trips before and after reopening the cache",
        arguments: [0, 1, 65_536, 65_537, 300_000]
    )
    func untouchedBodyRoundTripsAcrossReopen(byteCount: Int) async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/untouched-\(byteCount)")
        let payload = Data((0..<byteCount).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let response = CachedResponse(data: payload, headers: ["ETag": "v1"])

        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, response)
        let first = try #require(await writer.get(key))
        #expect(first.data == payload)
        #expect(first.headers["ETag"] == "v1")
        #expect(await writer.statistics().evictionCount == 0)

        let reopened = try PersistentResponseCache(configuration: configuration)
        let second = try #require(await reopened.get(key))
        #expect(second.data == payload)
        #expect(second.headers["ETag"] == "v1")
        // A repeated hit verifies again rather than trusting the first read.
        #expect(await reopened.get(key)?.data == payload)

        let stats = await reopened.statistics()
        #expect(stats.entryCount == 1)
        #expect(stats.hitCount == 2)
        #expect(stats.missCount == 0)
        #expect(stats.evictionCount == 0)
        #expect(await reopened.telemetrySnapshot().isEmpty)
        #expect(try existingBodyURLs(in: directory).count == 1)
    }

    // FIPS 180-4 SHA-256 vectors, so the persisted digest is checked against
    // values derived independently of the cache's own hashing call.
    @Test(
        "set() records the exact body byte count and SHA-256 digest in the index",
        arguments: [
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ]
    )
    func setRecordsBodyByteCountAndSHA256Digest(body: String, expectedDigestHex: String) async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/recorded-digest")

        await cache.set(key, CachedResponse(data: Data(body.utf8), headers: ["ETag": "v1"]))

        let index = try indexObject(in: directory)
        #expect(index["version"] as? Int == 5)
        let entries = try #require(index["entries"] as? [String: Any])
        #expect(entries.count == 1)
        let entry = try #require(entries.values.first as? [String: Any])
        // `byteCost` keeps charging header bytes to the budget; the exact
        // body length is recorded separately for verification.
        #expect(entry["byteCost"] as? Int == body.utf8.count + "ETag".utf8.count + "v1".utf8.count)
        #expect(entry["bodyByteCount"] as? Int == body.utf8.count)
        let encodedDigest = try #require(entry["bodySHA256"] as? String)
        let digest = try #require(Data(base64Encoded: encodedDigest))
        #expect(digest.map { String(format: "%02x", $0) }.joined() == expectedDigestHex)
    }

    // The index is untrusted input: a recorded length or digest that cannot
    // describe the intact body must scrub the entry, never serve or trap.
    @Test(
        "A recorded length or digest that disagrees with an intact body scrubs the entry",
        arguments: PersistentCacheRecordedIntegrityCorruption.allCases
    )
    func getScrubsEntryWithCorruptRecordedIntegrity(
        corruption: PersistentCacheRecordedIntegrityCorruption
    ) async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/corrupt-recorded-integrity")
        let payload = Data("integrity-protected-body".utf8)
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: payload))
        let bodySnapshot = try bodySnapshots(in: directory)

        switch corruption {
        case .emptyDigest:
            try rewriteFirstIndexEntry(in: directory, field: "bodySHA256", value: "")
        case .shortDigest:
            try rewriteFirstIndexEntry(
                in: directory, field: "bodySHA256", value: Data(repeating: 0xAB, count: 5).base64EncodedString())
        case .zeroedDigest:
            try rewriteFirstIndexEntry(
                in: directory, field: "bodySHA256", value: Data(count: 32).base64EncodedString())
        case .overlongDigest:
            try rewriteFirstIndexEntry(
                in: directory, field: "bodySHA256", value: Data(repeating: 0xAB, count: 64).base64EncodedString())
        case .negativeByteCount:
            try rewriteFirstIndexEntry(in: directory, field: "bodyByteCount", value: -1)
        case .offByOneByteCount:
            try rewriteFirstIndexEntry(in: directory, field: "bodyByteCount", value: payload.count + 1)
        }
        // The body itself is untouched; only the index disagrees with it.
        #expect(try bodySnapshots(in: directory) == bodySnapshot)

        let cache = try PersistentResponseCache(configuration: configuration)
        switch corruption {
        case .negativeByteCount, .offByOneByteCount:
            // A recorded length the body file does not have is scrubbed when
            // the cache opens, before any lookup.
            try await expectOpenTimeLengthScrub(in: cache, directory: directory, scrubbedByteCost: payload.count)
            #expect(await cache.get(key) == nil)
            try await expectFreshEntryRoundTrips(in: cache, key: key, directory: directory)
            return
        case .emptyDigest, .shortDigest, .zeroedDigest, .overlongDigest:
            break
        }
        let prior = await cache.statistics()
        #expect(prior.entryCount == 1)

        #expect(await cache.get(key) == nil)

        try await expectBodyIntegrityScrub(
            in: cache,
            directory: directory,
            prior: prior,
            scrubbedByteCost: payload.count
        )
        try await expectFreshEntryRoundTrips(in: cache, key: key, directory: directory)
    }

    @Test("Opening removes a staging file a crash left behind, never one still being written")
    func openRemovesOnlyAbandonedStagingFiles() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/staging-files")
        let payload = Data("kept-body".utf8)
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: payload))

        let bodiesURL = directory.appendingPathComponent("bodies", isDirectory: true)
        let abandoned = bodiesURL.appendingPathComponent(".abandoned.body.tmp-\(UUID().uuidString)")
        let inFlight = bodiesURL.appendingPathComponent(".in-flight.body.tmp-\(UUID().uuidString)")
        try Data("partial".utf8).write(to: abandoned)
        try Data("partial".utf8).write(to: inFlight)
        let staleDate = Date().addingTimeInterval(-(PersistentResponseCache.abandonedStagingAge + 60))
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: abandoned.path)

        let reopened = try PersistentResponseCache(configuration: configuration)

        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: inFlight.path))
        #expect(await reopened.get(key)?.data == payload)
    }

    @Test("A version 4 index without body digests cold-resets on open")
    func versionFourIndexColdResetsOnOpen() async throws {
        #expect(PersistentResponseCache.formatVersion == 5)
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let keys = (0..<3).map { ResponseCacheKey(method: "GET", url: "https://example.com/version-four-\($0)") }
        let writer = try PersistentResponseCache(configuration: configuration)
        for key in keys {
            await writer.set(key, CachedResponse(data: Data("legacy-\(key.url)".utf8)))
        }
        #expect(try existingBodyURLs(in: directory).count == keys.count)
        let sentinelURL = directory.appendingPathComponent("caller-owned.txt", isDirectory: false)
        let sentinel = Data("keep-me".utf8)
        try sentinel.write(to: sentinelURL)
        let hmacKey = try Data(contentsOf: hmacKeyURL(in: directory))

        try rewriteIndex(in: directory, version: 4, removingBodyIntegrityFields: true)

        // Must open without throwing: a cold reset is the intended upgrade.
        let reopened = try PersistentResponseCache(configuration: configuration)

        let stats = await reopened.statistics()
        #expect(stats.entryCount == 0)
        #expect(stats.byteCount == 0)
        for key in keys {
            #expect(await reopened.get(key) == nil)
        }
        // No leaked bodies or staging files, and only cache-owned state is
        // reset: the caller's file and the HMAC key survive.
        let bodiesURL = directory.appendingPathComponent("bodies", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bodiesURL.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: indexURL(in: directory).path))
        #expect(try Data(contentsOf: sentinelURL) == sentinel)
        #expect(try Data(contentsOf: hmacKeyURL(in: directory)) == hmacKey)
        // A format reset is not reported as per-entry integrity failures.
        #expect(await reopened.statistics().evictionCount == 0)
        #expect(await reopened.telemetrySnapshot().isEmpty)

        let fresh = Data("fresh".utf8)
        await reopened.set(keys[0], CachedResponse(data: fresh))
        #expect(await reopened.get(keys[0])?.data == fresh)
        #expect(try indexObject(in: directory)["version"] as? Int == 5)

        let reopenedAgain = try PersistentResponseCache(configuration: configuration)
        #expect(await reopenedAgain.get(keys[0])?.data == fresh)
        #expect(await reopenedAgain.statistics().entryCount == 1)
    }

    @Test("A current-version index entry without a digest is never served")
    func currentVersionEntryWithoutDigestColdResets() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/digestless-entry")
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, CachedResponse(data: Data("unverifiable".utf8)))
        #expect(try existingBodyURLs(in: directory).count == 1)

        try rewriteIndex(
            in: directory,
            version: PersistentResponseCache.formatVersion,
            removingBodyIntegrityFields: true
        )

        let reopened = try PersistentResponseCache(configuration: configuration)

        #expect(await reopened.get(key) == nil)
        #expect(await reopened.statistics().entryCount == 0)
        #expect(try existingBodyURLs(in: directory).isEmpty)

        let fresh = Data("fresh".utf8)
        await reopened.set(key, CachedResponse(data: fresh))
        #expect(await reopened.get(key)?.data == fresh)
    }

    @Test(
        "A stale integrity mismatch never scrubs the entry that replaced it",
        .timeLimit(.minutes(1))
    )
    func staleIntegrityMismatchDoesNotScrubReplacementEntry() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = StalledCorruptingPersistentCacheBodyReader()
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory),
            fileManager: .default,
            storageIO: PersistentResponseCache.StorageIO(
                bodyReader: { fileName, directoryURL, maximumByteCount in
                    try await reader.read(
                        fileName: fileName,
                        in: directoryURL,
                        maximumByteCount: maximumByteCount
                    )
                }
            )
        )
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/replaced-during-read")
        let original = Data("original-body".utf8)
        let replacement = Data("replacement-body".utf8)
        await cache.set(key, CachedResponse(data: original))

        // The first read is parked off the actor after it has the original
        // bytes; the actor is free to replace the entry before it resumes.
        async let staleRead = cache.get(key)
        await reader.waitUntilFirstReadStarted()
        await cache.set(key, CachedResponse(data: replacement))
        await reader.release()

        #expect(await staleRead == nil)
        let stats = await cache.statistics()
        #expect(stats.entryCount == 1)
        #expect(stats.missCount == 1)
        #expect(stats.evictionCount == 0)
        #expect(await cache.telemetrySnapshot().isEmpty)
        #expect(try existingBodyURLs(in: directory).count == 1)
        #expect(try indexEntryCount(in: directory) == 1)
        #expect(await cache.get(key)?.data == replacement)
    }

    @Test("Concurrent reads of one corrupt body all miss and scrub it exactly once")
    func concurrentReadsOfCorruptBodyScrubOnce() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/concurrent-corrupt-reads")
        let payload = Data(repeating: 0x5A, count: 200_000)
        await cache.set(key, CachedResponse(data: payload))
        let bodyURL = try #require(existingBodyURLs(in: directory).first)
        try flipByteInPlace(at: bodyURL, offset: payload.count - 1)
        let prior = await cache.statistics()
        let readerCount = 16

        let servedCount = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<readerCount {
                group.addTask { await cache.get(key) != nil }
            }
            var served = 0
            for await wasServed in group where wasServed {
                served += 1
            }
            return served
        }

        #expect(servedCount == 0)
        let stats = await cache.statistics()
        #expect(stats.entryCount == 0)
        #expect(stats.hitCount == prior.hitCount)
        #expect(stats.missCount == prior.missCount + readerCount)
        #expect(stats.evictionCount == prior.evictionCount + 1)
        #expect(
            await cache.telemetrySnapshot()
                == [.scrubbedEntries(reason: .bodyIntegrityMismatch, count: 1, byteCount: payload.count)]
        )
        #expect(try existingBodyURLs(in: directory).isEmpty)
        #expect(try indexEntryCount(in: directory) == 0)
    }

    @Test("A failed index flush after an integrity scrub is reported and the body stays unserved")
    func integrityScrubReportsIndexPersistenceFailure() async throws {
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
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/integrity-persist-fail")
        await cache.set(key, CachedResponse(data: Data("payload".utf8)))
        let bodyURL = try #require(existingBodyURLs(in: directory).first)
        try flipByteInPlace(at: bodyURL, offset: 0)

        // Make the best-effort index flush fail by occupying its path with a
        // directory, as the read-metadata persistence test does.
        let indexFileURL = indexURL(in: directory)
        try FileManager.default.removeItem(at: indexFileURL)
        try FileManager.default.createDirectory(at: indexFileURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: indexFileURL) }

        #expect(await cache.get(key) == nil)

        #expect(maintenanceFailures.snapshot() == [.scrubBodyIntegrityMismatch])
        #expect(await cache.statistics().entryCount == 0)
        #expect(try existingBodyURLs(in: directory).isEmpty)
        #expect(
            await cache.telemetrySnapshot()
                == [.scrubbedEntries(reason: .bodyIntegrityMismatch, count: 1, byteCount: 7)]
        )
        #expect(await cache.get(key) == nil)
    }

    /// Asserts the observable result of one integrity scrub: the entry and
    /// its body file are gone from memory and disk, the lookup counted as a
    /// miss, and telemetry carries exactly the dedicated reason.
    func expectBodyIntegrityScrub(
        in cache: PersistentResponseCache,
        directory: URL,
        prior: PersistentResponseCacheStatistics,
        scrubbedByteCost: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        #expect(try existingBodyURLs(in: directory).isEmpty, sourceLocation: sourceLocation)
        #expect(try indexEntryCount(in: directory) == 0, sourceLocation: sourceLocation)
        let stats = await cache.statistics()
        #expect(stats.entryCount == 0, sourceLocation: sourceLocation)
        #expect(stats.byteCount == 0, sourceLocation: sourceLocation)
        #expect(stats.hitCount == prior.hitCount, sourceLocation: sourceLocation)
        #expect(stats.missCount == prior.missCount + 1, sourceLocation: sourceLocation)
        #expect(stats.evictionCount == prior.evictionCount + 1, sourceLocation: sourceLocation)
        #expect(
            await cache.telemetrySnapshot()
                == [.scrubbedEntries(reason: .bodyIntegrityMismatch, count: 1, byteCount: scrubbedByteCost)],
            sourceLocation: sourceLocation
        )
    }

    /// Opening compares each body file's length with its recorded byte count,
    /// so a length mismatch is scrubbed before any lookup and reported with
    /// the same reason a lookup would report.
    func expectOpenTimeLengthScrub(
        in cache: PersistentResponseCache,
        directory: URL,
        scrubbedByteCost: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        #expect(try existingBodyURLs(in: directory).isEmpty, sourceLocation: sourceLocation)
        #expect(try indexEntryCount(in: directory) == 0, sourceLocation: sourceLocation)
        let stats = await cache.statistics()
        #expect(stats.entryCount == 0, sourceLocation: sourceLocation)
        #expect(stats.byteCount == 0, sourceLocation: sourceLocation)
        #expect(
            await cache.telemetrySnapshot()
                == [.scrubbedEntries(reason: .bodyIntegrityMismatch, count: 1, byteCount: scrubbedByteCost)],
            sourceLocation: sourceLocation
        )
    }

    /// A scrubbed key must behave like any other miss: the next write is
    /// stored and served, and it survives a reopen.
    func expectFreshEntryRoundTrips(
        in cache: PersistentResponseCache,
        key: ResponseCacheKey,
        directory: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let replacement = Data("replacement-after-scrub".utf8)
        await cache.set(key, CachedResponse(data: replacement))
        #expect(await cache.get(key)?.data == replacement, sourceLocation: sourceLocation)
        #expect(await cache.statistics().entryCount == 1, sourceLocation: sourceLocation)
        #expect(try existingBodyURLs(in: directory).count == 1, sourceLocation: sourceLocation)

        let reopened = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        #expect(await reopened.get(key)?.data == replacement, sourceLocation: sourceLocation)
    }

    /// Flips every bit of one byte without replacing the file, so the inode,
    /// link count, and length the cache admits stay exactly as written.
    func flipByteInPlace(at url: URL, offset: Int) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let original = try handle.read(upToCount: 1), let byte = original.first else {
            throw testFixtureError("No byte at offset \(offset) in \(url.lastPathComponent)")
        }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: Data([byte ^ 0xFF]))
    }

    /// Truncates (or zero-extends) the file without replacing it.
    func resizeInPlace(_ url: URL, toByteCount byteCount: Int) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(byteCount))
    }

    /// Replaces one field of the only index entry, leaving the body file alone.
    func rewriteFirstIndexEntry(in directory: URL, field: String, value: Any) throws {
        var index = try indexObject(in: directory)
        guard var entries = index["entries"] as? [String: Any],
            let entryID = entries.keys.sorted().first,
            var entry = entries[entryID] as? [String: Any],
            entry[field] != nil
        else {
            throw testFixtureError("Missing persistent cache entry field \(field) to rewrite")
        }
        entry[field] = value
        entries[entryID] = entry
        index["entries"] = entries
        let data = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
        try data.write(to: indexURL(in: directory), options: .atomic)
    }

    /// Rewrites the on-disk index with `version`. Removing the body length
    /// and digest fields reproduces exactly what the version 4 writer
    /// emitted, since version 5 only added those two entry fields.
    func rewriteIndex(
        in directory: URL,
        version: Int,
        removingBodyIntegrityFields: Bool
    ) throws {
        var index = try indexObject(in: directory)
        guard let entries = index["entries"] as? [String: Any], !entries.isEmpty else {
            throw testFixtureError("Missing persistent cache index entries")
        }
        var rewrittenEntries: [String: Any] = [:]
        for (id, value) in entries {
            guard var entry = value as? [String: Any] else {
                throw testFixtureError("Persistent cache index entry is not a JSON object")
            }
            if removingBodyIntegrityFields {
                guard
                    entry.removeValue(forKey: "bodyByteCount") != nil,
                    entry.removeValue(forKey: "bodySHA256") != nil
                else {
                    throw testFixtureError("Index entry is missing its body integrity fields")
                }
            }
            rewrittenEntries[id] = entry
        }
        index["version"] = version
        index["entries"] = rewrittenEntries
        let data = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
        try data.write(to: indexURL(in: directory), options: .atomic)
    }
}

/// Ways a persisted entry's recorded integrity fields can disagree with a body
/// that is itself intact.
enum PersistentCacheRecordedIntegrityCorruption: Sendable, CaseIterable {
    case emptyDigest
    case shortDigest
    case zeroedDigest
    case overlongDigest
    case negativeByteCount
    case offByOneByteCount
}

/// Parks the first body read off the cache actor until the test releases it,
/// then returns corrupted bytes. Later reads pass through untouched. This
/// models an integrity failure that is only discovered after a concurrent
/// `set` already replaced the entry.
actor StalledCorruptingPersistentCacheBodyReader {
    private var readCount = 0
    private var firstReadStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func read(
        fileName: String,
        in directoryURL: URL,
        maximumByteCount: Int
    ) async throws -> Data {
        readCount += 1
        let isFirstRead = readCount == 1
        let data = try await PersistentResponseCache.readBodyData(
            fileName: fileName,
            in: directoryURL,
            maximumByteCount: maximumByteCount
        )
        guard isFirstRead else { return data }

        firstReadStarted = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        var corrupted = data
        corrupted[corrupted.startIndex] ^= 0xFF
        return corrupted
    }

    func waitUntilFirstReadStarted() async {
        if firstReadStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}
