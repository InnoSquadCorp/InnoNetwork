import Foundation
import Testing

@testable import InnoNetworkDownload

@Suite("Download completion journal restoration", .serialized)
struct DownloadCompletionJournalRestoreTests {
    @Test("An active row with a durable payload commits before URLSession adoption")
    func activeJournalReplays() async throws {
        let fixture = try JournalRestoreFixture(label: "active")
        defer { fixture.cleanup() }
        let completion = try fixture.stagePayload("active payload")
        let record = fixture.record(lifecycle: .active)

        let harness = try fixture.makeHarness(records: [record])
        #expect(await harness.manager.waitForRestoration())

        #expect(try Data(contentsOf: fixture.destinationURL) == Data("active payload".utf8))
        #expect(await harness.persistence.record(forID: fixture.taskID) == nil)
        #expect(await harness.manager.task(withId: fixture.taskID) == nil)
        #expect(throws: Error.self) {
            try fixture.stager.load(forKey: completion.manifest.key)
        }
        await harness.manager.shutdown()
    }

    @Test("A committing row replays the exact journal and cancels a duplicate live transport")
    func committingJournalReplaysAndCancelsLiveTransport() async throws {
        let fixture = try JournalRestoreFixture(label: "committing-live")
        defer { fixture.cleanup() }
        let completion = try fixture.stagePayload("committing payload")
        let liveTask = StubDownloadURLTask(
            request: URLRequest(url: fixture.sourceURL),
            initialState: .running
        )
        liveTask.taskDescription = fixture.taskID
        let record = fixture.record(
            lifecycle: .committing,
            commitMetadata: fixture.metadata(for: completion)
        )

        let harness = try fixture.makeHarness(
            records: [record],
            preinstalledStubs: [liveTask]
        )
        #expect(await harness.manager.waitForRestoration())

        #expect(liveTask.cancelCount == 1)
        #expect(try Data(contentsOf: fixture.destinationURL) == Data("committing payload".utf8))
        #expect(await harness.persistence.record(forID: fixture.taskID) == nil)
        #expect(await harness.manager.task(withId: fixture.taskID) == nil)
        await harness.manager.shutdown()
    }

    @Test("Terminal metadata prunes bounded residue without emitting another completion")
    func terminalJournalResidueIsPruned() async throws {
        let fixture = try JournalRestoreFixture(label: "terminal-residue")
        defer { fixture.cleanup() }
        let completion = try fixture.stagePayload("already committed")
        try FileManager.default.createDirectory(
            at: fixture.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("final".utf8).write(to: fixture.destinationURL)
        let destinationStageURL = fixture.destinationStageURL(for: completion)
        try Data("partial".utf8).write(to: destinationStageURL)
        let record = fixture.record(
            lifecycle: .terminal,
            commitMetadata: fixture.metadata(for: completion)
        )

        let harness = try fixture.makeHarness(records: [record])
        #expect(await harness.manager.waitForRestoration())

        #expect(try Data(contentsOf: fixture.destinationURL) == Data("final".utf8))
        #expect(FileManager.default.fileExists(atPath: destinationStageURL.path) == false)
        #expect(await harness.persistence.record(forID: fixture.taskID) == nil)
        #expect(await harness.manager.task(withId: fixture.taskID) == nil)
        #expect(throws: Error.self) {
            try fixture.stager.load(forKey: completion.manifest.key)
        }
        await harness.manager.shutdown()
    }

    @Test("A final file without its committing source is never inferred as success")
    func finalFileWithoutSourceFailsClosed() async throws {
        let fixture = try JournalRestoreFixture(label: "final-only")
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("untrusted final".utf8).write(to: fixture.destinationURL)
        let key = try DownloadCompletionStager.stagingKey(forTaskID: fixture.taskID)
        let metadata = DownloadTaskPersistence.CommitMetadata(
            stagingKey: key,
            originalRequestURL: fixture.sourceURL,
            currentRequestURL: fixture.sourceURL,
            destinationURL: fixture.destinationURL,
            expectedByteCount: 99,
            payloadSHA256: String(repeating: "0", count: 64)
        )
        let record = fixture.record(
            lifecycle: .committing,
            commitMetadata: metadata
        )

        let harness = try fixture.makeHarness(records: [record])
        #expect(await harness.manager.waitForRestoration())
        let task = try #require(await harness.manager.task(withId: fixture.taskID))

        #expect(await task.state == .failed)
        guard case .some(.restorationMissingSystemTask) = await task.error else {
            Issue.record("Expected restorationMissingSystemTask")
            return
        }
        #expect(try Data(contentsOf: fixture.destinationURL) == Data("untrusted final".utf8))
        #expect(await harness.persistence.record(forID: fixture.taskID) == nil)
        await harness.manager.shutdown()
    }

    @Test("A finished receipt is delivered once to a late completion handler and acknowledged")
    func finishedReceiptDrainsToLateHandler() async throws {
        let fixture = try JournalRestoreFixture(label: "finished-handler")
        defer { fixture.cleanup() }
        let completion = try fixture.stagePayload("durable finished payload")
        let payload = try Data(contentsOf: completion.payloadURL)
        try FileManager.default.createDirectory(
            at: fixture.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: fixture.destinationURL)
        let record = fixture.record(
            lifecycle: .terminal,
            commitMetadata: fixture.metadata(for: completion),
            commitOutcome: .finished
        )

        let harness = try fixture.makeHarness(records: [record])
        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: fixture.taskID))
        #expect(await restored.state == .completed)
        #expect(await harness.persistence.record(forID: fixture.taskID)?.commitOutcome == .finished)

        let probe = RestoredCompletionProbe()
        await harness.manager.setOnCompletedHandler { task, location in
            await probe.record(taskID: task.id, location: location)
        }
        let taskID = fixture.taskID

        #expect(
            await waitForJournalCondition {
                let count = await probe.count
                let persisted = await harness.persistence.record(forID: taskID)
                return count == 1 && persisted == nil
            }
        )
        #expect(await probe.taskID == fixture.taskID)
        #expect(await probe.location == fixture.destinationURL)
        #expect(await harness.manager.task(withId: fixture.taskID) == nil)
        await harness.manager.shutdown()
    }

    @Test("A finished receipt is acknowledged after its terminal event is admitted")
    func finishedReceiptDrainsToEventStream() async throws {
        let fixture = try JournalRestoreFixture(label: "finished-event")
        defer { fixture.cleanup() }
        let completion = try fixture.stagePayload("durable event payload")
        try FileManager.default.createDirectory(
            at: fixture.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contentsOf: completion.payloadURL).write(to: fixture.destinationURL)
        let record = fixture.record(
            lifecycle: .terminal,
            commitMetadata: fixture.metadata(for: completion),
            commitOutcome: .finished
        )

        let harness = try fixture.makeHarness(records: [record])
        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: fixture.taskID))
        let stream = await harness.manager.events(for: restored)
        var iterator = stream.makeAsyncIterator()

        switch await iterator.next() {
        case .some(.completed(let location)):
            #expect(location == fixture.destinationURL)
        default:
            Issue.record("Expected the restored completed event")
        }
        #expect(await harness.persistence.record(forID: fixture.taskID) == nil)
        #expect(await harness.manager.task(withId: fixture.taskID) == nil)
        await harness.manager.shutdown()
    }

    @Test("A corrupted finished destination preserves its recoverable payload and receipt")
    func corruptedFinishedDestinationPreservesEvidence() async throws {
        let fixture = try JournalRestoreFixture(label: "finished-integrity")
        defer { fixture.cleanup() }
        let completion = try fixture.stagePayload("trusted journal bytes")
        try FileManager.default.createDirectory(
            at: fixture.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("tampered final bytes".utf8).write(to: fixture.destinationURL)
        let record = fixture.record(
            lifecycle: .terminal,
            commitMetadata: fixture.metadata(for: completion),
            commitOutcome: .finished
        )

        let harness = try fixture.makeHarness(records: [record])
        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: fixture.taskID))

        #expect(await restored.state == .failed)
        guard case .fileSystemError(let integrityError)? = await restored.error else {
            Issue.record("Expected a filesystem integrity failure")
            await harness.manager.shutdown()
            return
        }
        #expect(integrityError.domain == "InnoNetworkDownload.Restoration")
        #expect(integrityError.message.contains("integrity validation"))
        #expect(await harness.persistence.record(forID: fixture.taskID)?.commitOutcome == .finished)
        #expect(try fixture.stager.load(forKey: completion.manifest.key) == completion)
        #expect(try Data(contentsOf: fixture.destinationURL) == Data("tampered final bytes".utf8))
        await harness.manager.shutdown()
        #expect(await harness.persistence.record(forID: fixture.taskID)?.commitOutcome == .finished)
    }

    @Test("Cancel retry cancelAll and shutdown preserve a recoverable committing journal")
    func lifecycleMutationsPreserveRecoverableJournal() async throws {
        let fixture = try JournalRestoreFixture(label: "lifecycle-protection")
        defer { fixture.cleanup() }
        let completion = try fixture.stagePayload("recover me")
        let blockedParent = fixture.rootURL.appendingPathComponent("blocked", isDirectory: false)
        try Data("not a directory".utf8).write(to: blockedParent)
        fixture.destinationURL = blockedParent.appendingPathComponent("payload.bin")
        let record = fixture.record(lifecycle: .active)

        let harness = try fixture.makeHarness(records: [record])
        #expect(await harness.manager.waitForRestoration())
        let task = try #require(await harness.manager.task(withId: fixture.taskID))
        #expect(await task.state == .failed)
        #expect(await harness.persistence.record(forID: fixture.taskID)?.lifecycle == .committing)

        await harness.manager.cancel(task)
        await harness.manager.retry(task)
        await harness.manager.cancelAll()
        #expect(await harness.persistence.record(forID: fixture.taskID)?.lifecycle == .committing)
        #expect(try fixture.stager.load(forKey: completion.manifest.key) == completion)

        await harness.manager.shutdown()
        #expect(await harness.persistence.record(forID: fixture.taskID)?.lifecycle == .committing)
        #expect(try fixture.stager.load(forKey: completion.manifest.key) == completion)
    }
}

private final class JournalRestoreFixture {
    let rootURL: URL
    let persistenceBaseURL: URL
    let sessionIdentifier: String
    let taskID: String
    let sourceURL = URL(string: "https://example.invalid/archive.zip")!
    var destinationURL: URL
    let stager: DownloadCompletionStager

    init(label: String) throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "InnoNetworkJournalRestore-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        let persistenceBaseURL = rootURL.appendingPathComponent("Persistence", isDirectory: true)
        let sessionIdentifier = "test.download.journal.\(label).\(UUID().uuidString)"
        self.rootURL = rootURL
        self.persistenceBaseURL = persistenceBaseURL
        self.sessionIdentifier = sessionIdentifier
        self.taskID = "journal-task-\(label)-\(UUID().uuidString)"
        self.destinationURL =
            rootURL
            .appendingPathComponent("Output", isDirectory: true)
            .appendingPathComponent("archive.zip", isDirectory: false)
        self.stager = DownloadCompletionStager(
            directoryURL:
                persistenceBaseURL
                .appendingPathComponent("InnoNetworkDownload", isDirectory: true)
                .appendingPathComponent(sessionIdentifier, isDirectory: true)
                .appendingPathComponent("CompletionStaging", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func stagePayload(_ value: String) throws -> StagedCompletion {
        let source = rootURL.appendingPathComponent("source-\(UUID().uuidString).tmp")
        try Data(value.utf8).write(to: source)
        return try stager.stage(
            source,
            taskID: taskID,
            originalRequestURL: sourceURL,
            currentRequestURL: sourceURL
        )
    }

    func metadata(for completion: StagedCompletion) -> DownloadTaskPersistence.CommitMetadata {
        DownloadTaskPersistence.CommitMetadata(
            stagingKey: completion.manifest.key,
            originalRequestURL: completion.manifest.originalRequestURL,
            currentRequestURL: completion.manifest.currentRequestURL,
            destinationURL: destinationURL,
            expectedByteCount: completion.manifest.expectedByteCount,
            payloadSHA256: try! stager.payloadSHA256(for: completion)
        )
    }

    func record(
        lifecycle: DownloadTaskPersistence.Record.Lifecycle,
        commitMetadata: DownloadTaskPersistence.CommitMetadata? = nil,
        commitOutcome: DownloadTaskPersistence.CommitOutcome? = nil
    ) -> DownloadTaskPersistence.Record {
        DownloadTaskPersistence.Record(
            id: taskID,
            url: sourceURL,
            destinationURL: destinationURL,
            lifecycle: lifecycle,
            commitMetadata: commitMetadata,
            commitOutcome: commitOutcome
        )
    }

    func makeHarness(
        records: [DownloadTaskPersistence.Record],
        preinstalledStubs: [StubDownloadURLTask] = []
    ) throws -> StubDownloadHarness {
        try StubDownloadHarness(
            maxRetryCount: 0,
            label: "journal-restore",
            sessionIdentifier: sessionIdentifier,
            persistenceBaseDirectoryURL: persistenceBaseURL,
            prepopulatedRecords: records,
            preinstalledStubs: preinstalledStubs
        )
    }

    func destinationStageURL(for completion: StagedCompletion) -> URL {
        destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).innonetwork-\(completion.manifest.key).commit"
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private actor RestoredCompletionProbe {
    private(set) var count = 0
    private(set) var taskID: String?
    private(set) var location: URL?

    func record(taskID: String, location: URL) {
        count += 1
        self.taskID = taskID
        self.location = location
    }
}

private func waitForJournalCondition(
    timeout: Duration = .seconds(2),
    predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await predicate()
}
