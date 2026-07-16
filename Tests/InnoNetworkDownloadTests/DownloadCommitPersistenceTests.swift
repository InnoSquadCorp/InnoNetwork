import Foundation
import Testing

@testable import InnoNetworkDownload

@Suite("Download Commit Persistence Tests")
struct DownloadCommitPersistenceTests {
    @Test("Legacy records and events decode without commit fields")
    func backwardDecodeMissingCommitMetadata() throws {
        struct LegacyRecord: Codable {
            let id: String
            let url: URL
            let destinationURL: URL
            let resumeData: Data?
            let lifecycle: DownloadTaskPersistence.Record.Lifecycle?
            let retryCount: Int?
            let totalRetryCount: Int?
            let retryPlan: DownloadTaskPersistence.RetryPlan?
        }

        struct LegacyEvent: Codable {
            let sequence: Int64
            let timestamp: Date
            let kind: AppendLogDownloadTaskStore.EventKind
            let taskID: String
            let url: URL?
            let destinationURL: URL?
            let resumeData: Data?
            let lifecycle: DownloadTaskPersistence.Record.Lifecycle?
            let retryCount: Int?
            let totalRetryCount: Int?
            let retryPlan: DownloadTaskPersistence.RetryPlan?
        }

        let url = URL(string: "https://example.invalid/legacy.bin")!
        let destinationURL = URL(fileURLWithPath: "/tmp/legacy.bin")
        let legacyRecord = LegacyRecord(
            id: "legacy",
            url: url,
            destinationURL: destinationURL,
            resumeData: nil,
            lifecycle: .active,
            retryCount: 1,
            totalRetryCount: 2,
            retryPlan: nil
        )
        let record = try JSONDecoder().decode(
            DownloadTaskPersistence.Record.self,
            from: JSONEncoder().encode(legacyRecord)
        )
        #expect(record.commitMetadata == nil)
        #expect(record.commitOutcome == nil)

        let legacyEvent = LegacyEvent(
            sequence: 0,
            timestamp: Date(timeIntervalSince1970: 1),
            kind: .upsert,
            taskID: "legacy",
            url: url,
            destinationURL: destinationURL,
            resumeData: nil,
            lifecycle: .active,
            retryCount: 1,
            totalRetryCount: 2,
            retryPlan: nil
        )
        let event = try JSONDecoder().decode(
            AppendLogDownloadTaskStore.Event.self,
            from: JSONEncoder().encode(legacyEvent)
        )
        #expect(event.commitMetadata == nil)
        #expect(event.commitOutcome == nil)
    }

    @Test("Commit metadata survives append-log replay and checkpoint compaction")
    func commitMetadataRoundTrips() async throws {
        for maximumEvents in [Int.max, 1] {
            let fixture = makeDiskFixture(label: "roundtrip-\(maximumEvents)")
            defer { try? FileManager.default.removeItem(at: fixture.baseDirectory) }
            let policy = DownloadConfiguration.PersistenceCompactionPolicy(
                maxEvents: maximumEvents,
                maxLogBytes: UInt64.max,
                tombstoneRatio: 1
            )
            let writer = try DownloadTaskPersistence(
                sessionIdentifier: fixture.sessionIdentifier,
                baseDirectoryURL: fixture.baseDirectory,
                compactionPolicy: policy
            )
            try await writer.upsert(
                id: fixture.id,
                url: fixture.url,
                destinationURL: fixture.destinationURL
            )
            let metadata = makeMetadata(
                originalRequestURL: fixture.url,
                destinationURL: fixture.destinationURL,
                suffix: "roundtrip"
            )
            #expect(try await writer.beginCommit(id: fixture.id, metadata: metadata))

            let committingReader = try DownloadTaskPersistence(
                sessionIdentifier: fixture.sessionIdentifier,
                baseDirectoryURL: fixture.baseDirectory,
                compactionPolicy: policy
            )
            let committing = try #require(
                await committingReader.record(forID: fixture.id)
            )
            #expect(committing.lifecycle == .committing)
            #expect(committing.commitMetadata == metadata)
            #expect(committing.commitOutcome == nil)
            #expect(
                try await committingReader.finishCommit(
                    id: fixture.id,
                    metadata: metadata
                )
            )

            let terminalReader = try DownloadTaskPersistence(
                sessionIdentifier: fixture.sessionIdentifier,
                baseDirectoryURL: fixture.baseDirectory,
                compactionPolicy: policy
            )
            let terminal = try #require(
                await terminalReader.record(forID: fixture.id)
            )
            #expect(terminal.lifecycle == .terminal)
            #expect(terminal.commitMetadata == metadata)
            #expect(terminal.commitOutcome == .finished)
        }
    }

    @Test("Abandoned commit outcome survives append-log replay and checkpoint compaction")
    func abandonedCommitOutcomeRoundTrips() async throws {
        for maximumEvents in [Int.max, 1] {
            let fixture = makeDiskFixture(label: "abandoned-roundtrip-\(maximumEvents)")
            defer { try? FileManager.default.removeItem(at: fixture.baseDirectory) }
            let policy = DownloadConfiguration.PersistenceCompactionPolicy(
                maxEvents: maximumEvents,
                maxLogBytes: UInt64.max,
                tombstoneRatio: 1
            )
            let writer = try DownloadTaskPersistence(
                sessionIdentifier: fixture.sessionIdentifier,
                baseDirectoryURL: fixture.baseDirectory,
                compactionPolicy: policy
            )
            try await writer.upsert(
                id: fixture.id,
                url: fixture.url,
                destinationURL: fixture.destinationURL
            )
            let metadata = makeMetadata(
                originalRequestURL: fixture.url,
                destinationURL: fixture.destinationURL,
                suffix: "abandoned-roundtrip"
            )
            #expect(try await writer.beginCommit(id: fixture.id, metadata: metadata))
            #expect(try await writer.abandonCommit(id: fixture.id, metadata: metadata))

            let reader = try DownloadTaskPersistence(
                sessionIdentifier: fixture.sessionIdentifier,
                baseDirectoryURL: fixture.baseDirectory,
                compactionPolicy: policy
            )
            let terminal = try #require(await reader.record(forID: fixture.id))
            #expect(terminal.lifecycle == .terminal)
            #expect(terminal.commitMetadata == metadata)
            #expect(terminal.commitOutcome == .abandoned)
        }
    }

    @Test("beginCommit admits only recoverable live lifecycle states")
    func beginCommitLifecycleCAS() async throws {
        let url = URL(string: "https://example.invalid/admission.bin")!
        let destinationURL = URL(fileURLWithPath: "/tmp/admission.bin")
        let metadata = makeMetadata(originalRequestURL: url, suffix: "admission")
        let allowed: [DownloadTaskPersistence.Record.Lifecycle?] = [
            nil, .active, .pausing, .paused, .resuming,
        ]
        let disallowed: [DownloadTaskPersistence.Record.Lifecycle?] = [
            .retryPending, .committing, .terminal,
        ]

        for (index, lifecycle) in allowed.enumerated() {
            let id = "allowed-\(index)"
            let store = InMemoryDownloadTaskStore(
                seed: [
                    DownloadTaskPersistence.Record(
                        id: id,
                        url: url,
                        destinationURL: destinationURL,
                        resumeData: Data([0x01]),
                        lifecycle: lifecycle,
                        retryCount: 3,
                        totalRetryCount: 7
                    )
                ]
            )
            let persistence = DownloadTaskPersistence(store: store)
            #expect(try await persistence.beginCommit(id: id, metadata: metadata))
            let record = try #require(await persistence.record(forID: id))
            #expect(record.lifecycle == .committing)
            #expect(record.url == url)
            #expect(record.destinationURL == destinationURL)
            #expect(record.retryCount == 3)
            #expect(record.totalRetryCount == 7)
            #expect(record.commitMetadata == metadata)
            #expect(record.commitOutcome == nil)
        }

        for (index, lifecycle) in disallowed.enumerated() {
            let id = "disallowed-\(index)"
            let store = InMemoryDownloadTaskStore(
                seed: [
                    DownloadTaskPersistence.Record(
                        id: id,
                        url: url,
                        destinationURL: destinationURL,
                        lifecycle: lifecycle,
                        commitMetadata: lifecycle == .committing ? metadata : nil
                    )
                ]
            )
            let persistence = DownloadTaskPersistence(store: store)
            #expect(try await persistence.beginCommit(id: id, metadata: metadata) == false)
        }

        let empty = DownloadTaskPersistence(store: InMemoryDownloadTaskStore())
        #expect(try await empty.beginCommit(id: "missing", metadata: metadata) == false)
    }

    @Test("beginCommit validates journal evidence against the source record")
    func beginCommitRejectsUncorrelatedMetadata() async throws {
        let url = URL(string: "https://example.invalid/source.bin")!
        let id = "correlation"
        let persistence = DownloadTaskPersistence(
            store: InMemoryDownloadTaskStore(
                seed: [
                    DownloadTaskPersistence.Record(
                        id: id,
                        url: url,
                        destinationURL: URL(fileURLWithPath: "/tmp/source.bin"),
                        lifecycle: .active
                    )
                ]
            )
        )
        let wrongURL = makeMetadata(
            originalRequestURL: URL(string: "https://example.invalid/other.bin")!,
            suffix: "wrong-url"
        )
        let blankKey = DownloadTaskPersistence.CommitMetadata(
            stagingKey: " \n ",
            originalRequestURL: url,
            currentRequestURL: url,
            destinationURL: URL(fileURLWithPath: "/tmp/source.bin"),
            expectedByteCount: 1,
            payloadSHA256: String(repeating: "0", count: 64)
        )
        let negativeSize = DownloadTaskPersistence.CommitMetadata(
            stagingKey: String(repeating: "1", count: 64),
            originalRequestURL: url,
            currentRequestURL: url,
            destinationURL: URL(fileURLWithPath: "/tmp/source.bin"),
            expectedByteCount: -1,
            payloadSHA256: String(repeating: "2", count: 64)
        )

        #expect(try await persistence.beginCommit(id: id, metadata: wrongURL) == false)
        #expect(try await persistence.beginCommit(id: id, metadata: blankKey) == false)
        #expect(try await persistence.beginCommit(id: id, metadata: negativeSize) == false)
        #expect(await persistence.record(forID: id)?.lifecycle == .active)
    }

    @Test("finishCommit and abandonCommit require the exact journal metadata")
    func exactTerminalCommitCAS() async throws {
        let url = URL(string: "https://example.invalid/exact.bin")!
        let destinationURL = URL(fileURLWithPath: "/tmp/exact.bin")
        let firstID = "finish"
        let secondID = "abandon"
        let store = InMemoryDownloadTaskStore(
            seed: [
                DownloadTaskPersistence.Record(
                    id: firstID,
                    url: url,
                    destinationURL: destinationURL,
                    lifecycle: .active
                ),
                DownloadTaskPersistence.Record(
                    id: secondID,
                    url: url,
                    destinationURL: destinationURL,
                    lifecycle: .active
                ),
            ]
        )
        let persistence = DownloadTaskPersistence(store: store)
        let metadata = makeMetadata(originalRequestURL: url, suffix: "exact")
        let wrongMetadata = makeMetadata(originalRequestURL: url, suffix: "wrong")
        #expect(try await persistence.beginCommit(id: firstID, metadata: metadata))
        #expect(try await persistence.finishCommit(id: firstID, metadata: wrongMetadata) == false)
        #expect(try await persistence.abandonCommit(id: firstID, metadata: wrongMetadata) == false)
        #expect(try await persistence.finishCommit(id: secondID, metadata: metadata) == false)
        #expect(await persistence.record(forID: firstID)?.lifecycle == .committing)

        #expect(try await persistence.finishCommit(id: firstID, metadata: metadata))
        let finished = try #require(await persistence.record(forID: firstID))
        #expect(finished.lifecycle == .terminal)
        #expect(finished.commitMetadata == metadata)
        #expect(finished.commitOutcome == .finished)
        #expect(try await persistence.finishCommit(id: firstID, metadata: metadata) == false)
        #expect(
            try await persistence.acknowledgeCommitOutcome(
                id: firstID,
                metadata: wrongMetadata,
                outcome: .finished
            ) == false
        )
        #expect(
            try await persistence.acknowledgeCommitOutcome(
                id: firstID,
                metadata: metadata,
                outcome: .abandoned
            ) == false
        )
        #expect(await persistence.record(forID: firstID) != nil)
        #expect(
            try await persistence.acknowledgeCommitOutcome(
                id: firstID,
                metadata: metadata,
                outcome: .finished
            )
        )
        #expect(await persistence.record(forID: firstID) == nil)

        #expect(try await persistence.beginCommit(id: secondID, metadata: metadata))
        #expect(try await persistence.abandonCommit(id: secondID, metadata: metadata))
        let abandoned = try #require(await persistence.record(forID: secondID))
        #expect(abandoned.lifecycle == .terminal)
        #expect(abandoned.commitMetadata == metadata)
        #expect(abandoned.commitOutcome == .abandoned)
        #expect(
            try await persistence.acknowledgeCommitOutcome(
                id: secondID,
                metadata: metadata,
                outcome: .abandoned
            )
        )
        #expect(await persistence.record(forID: secondID) == nil)
    }

    @Test("abandonCommit supports an exact nil-metadata CAS for malformed committing rows")
    func abandonCommitExactNilMetadataCAS() async throws {
        let url = URL(string: "https://example.invalid/nil-metadata.bin")!
        let destinationURL = URL(fileURLWithPath: "/tmp/nil-metadata.bin")
        let nilMetadataID = "nil-metadata"
        let populatedMetadataID = "populated-metadata"
        let metadata = makeMetadata(originalRequestURL: url, suffix: "populated")
        let store = InMemoryDownloadTaskStore(
            seed: [
                DownloadTaskPersistence.Record(
                    id: nilMetadataID,
                    url: url,
                    destinationURL: destinationURL,
                    lifecycle: .committing
                ),
                DownloadTaskPersistence.Record(
                    id: populatedMetadataID,
                    url: url,
                    destinationURL: destinationURL,
                    lifecycle: .committing,
                    commitMetadata: metadata
                ),
            ]
        )
        let persistence = DownloadTaskPersistence(store: store)

        #expect(try await persistence.finishCommit(id: nilMetadataID, metadata: metadata) == false)
        #expect(try await persistence.abandonCommit(id: populatedMetadataID, metadata: nil) == false)
        #expect(await persistence.record(forID: nilMetadataID)?.lifecycle == .committing)
        #expect(await persistence.record(forID: populatedMetadataID)?.lifecycle == .committing)

        #expect(try await persistence.abandonCommit(id: nilMetadataID, metadata: nil))
        let abandonedNil = try #require(await persistence.record(forID: nilMetadataID))
        #expect(abandonedNil.lifecycle == .terminal)
        #expect(abandonedNil.commitMetadata == nil)
        #expect(abandonedNil.commitOutcome == .abandoned)
        #expect(try await persistence.abandonCommit(id: nilMetadataID, metadata: nil) == false)

        #expect(try await persistence.abandonCommit(id: populatedMetadataID, metadata: metadata))
        let abandonedPopulated = try #require(
            await persistence.record(forID: populatedMetadataID)
        )
        #expect(abandonedPopulated.lifecycle == .terminal)
        #expect(abandonedPopulated.commitMetadata == metadata)
        #expect(abandonedPopulated.commitOutcome == .abandoned)
    }

    @Test("Generic persistence mutations cannot alter or delete a committing row")
    func genericMutationsPreserveCommittingRecord() async throws {
        let fixture = makeDiskFixture(label: "generic-guard")
        defer { try? FileManager.default.removeItem(at: fixture.baseDirectory) }
        let persistence = try DownloadTaskPersistence(
            sessionIdentifier: fixture.sessionIdentifier,
            baseDirectoryURL: fixture.baseDirectory
        )
        try await persistence.upsert(
            id: fixture.id,
            url: fixture.url,
            destinationURL: fixture.destinationURL
        )
        let metadata = makeMetadata(
            originalRequestURL: fixture.url,
            destinationURL: fixture.destinationURL,
            suffix: "generic-guard"
        )
        #expect(try await persistence.beginCommit(id: fixture.id, metadata: metadata))

        let replacementURL = URL(string: "https://example.invalid/replacement.bin")!
        try await persistence.upsert(
            id: fixture.id,
            url: replacementURL,
            destinationURL: fixture.destinationURL,
            resumeData: Data([0x01])
        )
        for mode in [
            DownloadTaskPersistence.StartMode.initial,
            .automaticRetry,
            .manualRetry,
        ] {
            #expect(
                try await persistence.beginStart(
                    id: fixture.id,
                    url: replacementURL,
                    destinationURL: fixture.destinationURL,
                    mode: mode,
                    retryCount: 99,
                    totalRetryCount: 99
                ) == false
            )
        }
        try await persistence.updateResumeData(
            id: fixture.id,
            resumeData: Data([0x02]),
            lifecycle: .paused
        )
        #expect(
            try await persistence.transitionResumeState(
                id: fixture.id,
                from: .committing,
                to: .active,
                resumeData: nil
            ) == false
        )
        #expect(
            try await persistence.updateRetryState(
                id: fixture.id,
                retryCount: 99,
                totalRetryCount: 99
            ) == false
        )
        try await persistence.markTerminal(id: fixture.id)
        try await persistence.remove(id: fixture.id)
        try await persistence.remove(ids: [fixture.id])
        try await persistence.prune(keeping: [])

        let preserved = try #require(await persistence.record(forID: fixture.id))
        #expect(preserved.lifecycle == .committing)
        #expect(preserved.url == fixture.url)
        #expect(preserved.commitMetadata == metadata)
        #expect(preserved.commitOutcome == nil)

        #expect(try await persistence.finishCommit(id: fixture.id, metadata: metadata))
        try await persistence.remove(id: fixture.id)
        #expect(await persistence.record(forID: fixture.id) == nil)
    }

    @Test("Directory lock makes begin and terminal commit CAS atomic across stores")
    func multiStoreCommitRace() async throws {
        let fixture = makeDiskFixture(label: "multi-store")
        defer { try? FileManager.default.removeItem(at: fixture.baseDirectory) }
        let seed = try DownloadTaskPersistence(
            sessionIdentifier: fixture.sessionIdentifier,
            baseDirectoryURL: fixture.baseDirectory
        )
        try await seed.upsert(
            id: fixture.id,
            url: fixture.url,
            destinationURL: fixture.destinationURL
        )
        let first = try DownloadTaskPersistence(
            sessionIdentifier: fixture.sessionIdentifier,
            baseDirectoryURL: fixture.baseDirectory
        )
        let second = try DownloadTaskPersistence(
            sessionIdentifier: fixture.sessionIdentifier,
            baseDirectoryURL: fixture.baseDirectory
        )
        let firstMetadata = makeMetadata(
            originalRequestURL: fixture.url,
            destinationURL: fixture.destinationURL,
            suffix: "first"
        )
        let secondMetadata = makeMetadata(
            originalRequestURL: fixture.url,
            destinationURL: fixture.destinationURL,
            suffix: "second"
        )

        async let firstBegin = first.beginCommit(
            id: fixture.id,
            metadata: firstMetadata
        )
        async let secondBegin = second.beginCommit(
            id: fixture.id,
            metadata: secondMetadata
        )
        let (didFirstBegin, didSecondBegin) = try await (firstBegin, secondBegin)
        #expect(didFirstBegin != didSecondBegin)
        let winningMetadata = didFirstBegin ? firstMetadata : secondMetadata

        let afterBegin = try DownloadTaskPersistence(
            sessionIdentifier: fixture.sessionIdentifier,
            baseDirectoryURL: fixture.baseDirectory
        )
        let committing = try #require(await afterBegin.record(forID: fixture.id))
        #expect(committing.lifecycle == .committing)
        #expect(committing.commitMetadata == winningMetadata)

        async let finish = first.finishCommit(
            id: fixture.id,
            metadata: winningMetadata
        )
        async let abandon = second.abandonCommit(
            id: fixture.id,
            metadata: winningMetadata
        )
        let (didFinish, didAbandon) = try await (finish, abandon)
        #expect(didFinish != didAbandon)

        let verifier = try DownloadTaskPersistence(
            sessionIdentifier: fixture.sessionIdentifier,
            baseDirectoryURL: fixture.baseDirectory
        )
        let terminal = try #require(await verifier.record(forID: fixture.id))
        #expect(terminal.lifecycle == .terminal)
        #expect(terminal.commitMetadata == winningMetadata)
        #expect(terminal.commitOutcome == (didFinish ? .finished : .abandoned))
    }
}

private struct CommitPersistenceDiskFixture {
    let baseDirectory: URL
    let sessionIdentifier: String
    let id: String
    let url: URL
    let destinationURL: URL
}

private func makeDiskFixture(label: String) -> CommitPersistenceDiskFixture {
    let token = UUID().uuidString
    let baseDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("inno-commit-\(label)-\(token)", isDirectory: true)
    return CommitPersistenceDiskFixture(
        baseDirectory: baseDirectory,
        sessionIdentifier: "commit-\(label)-\(token)",
        id: "task-\(token)",
        url: URL(string: "https://example.invalid/\(label).bin")!,
        destinationURL: baseDirectory.appendingPathComponent("\(label).bin")
    )
}

private func makeMetadata(
    originalRequestURL: URL,
    destinationURL: URL? = nil,
    suffix: String
) -> DownloadTaskPersistence.CommitMetadata {
    DownloadTaskPersistence.CommitMetadata(
        stagingKey: try! DownloadCompletionStager.stagingKey(
            forTaskID: "stage-\(suffix)"
        ),
        originalRequestURL: originalRequestURL,
        currentRequestURL: URL(
            string: "https://cdn.example.invalid/\(suffix).bin"
        )!,
        destinationURL: destinationURL
            ?? URL(fileURLWithPath: "/tmp/\(originalRequestURL.lastPathComponent)"),
        expectedByteCount: 42,
        payloadSHA256: try! DownloadCompletionStager.stagingKey(
            forTaskID: "payload-\(suffix)"
        )
    )
}
