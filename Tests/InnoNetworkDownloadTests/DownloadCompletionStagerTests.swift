import Darwin
import Foundation
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkDownload

@Suite("Download completion staging")
struct DownloadCompletionStagerTests {
    @Test("Completion arriving before handler installation is buffered and delivered")
    func preHandlerCompletionIsBuffered() throws {
        let fileManager = FileManager.default
        let stagedURL = fileManager.temporaryDirectory.appendingPathComponent(
            "download-pre-handler-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        try Data("buffered".utf8).write(to: stagedURL)
        defer { try? fileManager.removeItem(at: stagedURL) }

        let capturedLocation = OSAllocatedUnfairLock<URL?>(initialState: nil)
        let callbacks = DownloadSessionDelegateCallbacks()
        callbacks.handleCompletion(taskIdentifier: 42, location: stagedURL, error: nil)

        #expect(capturedLocation.withLock { $0 } == nil)
        #expect(fileManager.fileExists(atPath: stagedURL.path))

        callbacks.setHandlers(
            onProgress: { _, _, _, _ in },
            onCompletion: { taskIdentifier, _, _, _, payload, _ in
                #expect(taskIdentifier == 42)
                capturedLocation.withLock { $0 = payload?.locationURL }
            }
        )

        #expect(capturedLocation.withLock { $0 } == stagedURL)
        #expect(fileManager.fileExists(atPath: stagedURL.path))
    }

    @Test("Buffered completion is cleaned if handlers are never installed")
    func abandonedPreHandlerCompletionIsCleaned() throws {
        let fileManager = FileManager.default
        let stagedURL = fileManager.temporaryDirectory.appendingPathComponent(
            "download-abandoned-handler-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        try Data("abandoned".utf8).write(to: stagedURL)
        defer { try? fileManager.removeItem(at: stagedURL) }

        enqueueCompletionWithoutInstallingHandler(location: stagedURL)

        #expect(fileManager.fileExists(atPath: stagedURL.path) == false)
    }

    @Test("Consumer removes a staged completion when its weak manager is gone")
    func missingConsumerOwnerRemovesStagedFile() async throws {
        let fileManager = FileManager.default
        let stagedURL = fileManager.temporaryDirectory.appendingPathComponent(
            "download-missing-owner-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        try Data("orphan".utf8).write(to: stagedURL)
        defer { try? fileManager.removeItem(at: stagedURL) }

        await DownloadManager.consumeDelegateEvent(
            .completion(
                taskIdentifier: 7,
                taskDescription: nil,
                originalRequestURL: nil,
                currentRequestURL: nil,
                payload: .legacy(stagedURL),
                error: nil
            ),
            manager: nil
        )

        #expect(fileManager.fileExists(atPath: stagedURL.path) == false)
    }

    @Test("Stale sweep removes only generated regular files from the staging directory")
    func staleSweepIsBoundedToGeneratedRegularFiles() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "InnoNetworkDownloadStaleSweepTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagingDirectoryURL = rootURL.appendingPathComponent("Staging", isDirectory: true)
        let staleURL = stagingDirectoryURL.appendingPathComponent("download-42-stale.tmp", isDirectory: false)
        let unrelatedURL = stagingDirectoryURL.appendingPathComponent("keep-me.txt", isDirectory: false)
        let nestedURL = stagingDirectoryURL.appendingPathComponent("download-directory.tmp", isDirectory: true)
        let symlinkTargetURL = rootURL.appendingPathComponent("outside-target.tmp", isDirectory: false)
        let symlinkURL = stagingDirectoryURL.appendingPathComponent("download-link.tmp", isDirectory: false)
        try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: staleURL)
        try Data("unrelated".utf8).write(to: unrelatedURL)
        try fileManager.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: symlinkTargetURL)
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: symlinkTargetURL)
        defer { try? fileManager.removeItem(at: rootURL) }

        DownloadCompletionStager(directoryURL: stagingDirectoryURL).removeStaleFiles(fileManager: fileManager)

        #expect(fileManager.fileExists(atPath: staleURL.path) == false)
        #expect(fileManager.fileExists(atPath: unrelatedURL.path))
        #expect(fileManager.fileExists(atPath: nestedURL.path))
        #expect(fileManager.fileExists(atPath: symlinkURL.path))
        #expect(fileManager.fileExists(atPath: symlinkTargetURL.path))
    }

    @Test("Delegate moves the completion file into library-owned storage before returning")
    func delegateStagesCompletionSynchronously() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "InnoNetworkDownloadStagingTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectoryURL = rootURL.appendingPathComponent("URLSession", isDirectory: true)
        let stagingDirectoryURL = rootURL.appendingPathComponent("Staging", isDirectory: true)
        let sourceURL = sourceDirectoryURL.appendingPathComponent("download.tmp", isDirectory: false)
        let payload = Data("delegate-owned-payload".utf8)
        try fileManager.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
        try payload.write(to: sourceURL)
        defer { try? fileManager.removeItem(at: rootURL) }

        let capturedLocation = OSAllocatedUnfairLock<URL?>(initialState: nil)
        let capturedError = OSAllocatedUnfairLock<SendableUnderlyingError?>(initialState: nil)
        let callbacks = DownloadSessionDelegateCallbacks()
        callbacks.setHandlers(
            onProgress: { _, _, _, _ in },
            onCompletion: { _, _, _, _, completionPayload, error in
                capturedLocation.withLock { $0 = completionPayload?.locationURL }
                capturedError.withLock { $0 = error }
            }
        )
        let delegate = DownloadSessionDelegate(
            callbacks: callbacks,
            backgroundCompletionStore: BackgroundCompletionStore(),
            completionStager: DownloadCompletionStager(directoryURL: stagingDirectoryURL)
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/file")!)
        task.taskDescription = "delegate-staging-\(UUID().uuidString)"

        delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: sourceURL)

        let stagedURL = try #require(capturedLocation.withLock { $0 })
        #expect(capturedError.withLock { $0 } == nil)
        #expect(!fileManager.fileExists(atPath: sourceURL.path))
        #expect(stagedURL.deletingLastPathComponent() == stagingDirectoryURL)
        #expect(try Data(contentsOf: stagedURL) == payload)
        #if canImport(Darwin)
        #expect(try completionStagingBackupExclusionIsApplied(to: stagingDirectoryURL))
        #endif
    }

    #if canImport(Darwin)
    @Test("Completion staging never transfers library backup metadata to the caller destination")
    func completionDoesNotMutateFinalDestinationMetadata() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "InnoNetworkDownloadDestinationMetadataTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectoryURL = rootURL.appendingPathComponent("URLSession", isDirectory: true)
        let stagingDirectoryURL = rootURL.appendingPathComponent("Staging", isDirectory: true)
        let sourceURL = sourceDirectoryURL.appendingPathComponent("download.tmp", isDirectory: false)
        let destinationURL = rootURL.appendingPathComponent("Caller", isDirectory: true)
            .appendingPathComponent("payload.bin", isDirectory: false)
        try fileManager.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: sourceURL)
        var mutableSourceURL = sourceURL
        var includedInBackup = URLResourceValues()
        includedInBackup.isExcludedFromBackup = false
        try mutableSourceURL.setResourceValues(includedInBackup)
        defer { try? fileManager.removeItem(at: rootURL) }

        let stagedURL = try DownloadCompletionStager(directoryURL: stagingDirectoryURL)
            .stage(sourceURL, taskIdentifier: 17)
        let configuration = DownloadConfiguration.default
        let persistence = DownloadTaskPersistence(store: InMemoryDownloadTaskStore())
        let coordinator = DownloadTransferCoordinator(
            session: StubDownloadURLSession(),
            runtimeRegistry: DownloadRuntimeRegistry(),
            persistence: persistence,
            eventHub: TaskEventHub(
                policy: configuration.eventDeliveryPolicy,
                metricsReporter: configuration.eventMetricsReporter,
                hubKind: .downloadTask
            ),
            lifecycleGate: DownloadLifecycleGate()
        )
        let task = DownloadTask(
            url: URL(string: "https://example.invalid/payload.bin")!,
            destinationURL: destinationURL
        )
        _ = try await persistence.beginStart(
            id: task.id,
            url: task.url,
            destinationURL: task.destinationURL,
            mode: .initial,
            retryCount: 0,
            totalRetryCount: 0
        )
        await task.updateState(.waiting)
        await task.updateState(.downloading)

        try await coordinator.completeDownload(task: task, temporaryLocation: stagedURL)

        #expect(try completionStagingBackupExclusionIsApplied(to: destinationURL) == false)
    }
    #endif

    @Test("Staging failure reports an error without losing the URLSession file")
    func delegateReportsStagingFailure() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "InnoNetworkDownloadStagingFailureTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceURL = rootURL.appendingPathComponent("download.tmp", isDirectory: false)
        let invalidStagingDirectoryURL = rootURL.appendingPathComponent("not-a-directory", isDirectory: false)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: sourceURL)
        try Data("blocking-file".utf8).write(to: invalidStagingDirectoryURL)
        defer { try? fileManager.removeItem(at: rootURL) }

        let capturedLocation = OSAllocatedUnfairLock<URL?>(initialState: nil)
        let capturedError = OSAllocatedUnfairLock<SendableUnderlyingError?>(initialState: nil)
        let callbacks = DownloadSessionDelegateCallbacks()
        callbacks.setHandlers(
            onProgress: { _, _, _, _ in },
            onCompletion: { _, _, _, _, completionPayload, error in
                capturedLocation.withLock { $0 = completionPayload?.locationURL }
                capturedError.withLock { $0 = error }
            }
        )
        let delegate = DownloadSessionDelegate(
            callbacks: callbacks,
            backgroundCompletionStore: BackgroundCompletionStore(),
            completionStager: DownloadCompletionStager(directoryURL: invalidStagingDirectoryURL)
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/file")!)
        task.taskDescription = "delegate-staging-failure-\(UUID().uuidString)"

        delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: sourceURL)

        #expect(capturedLocation.withLock { $0 } == nil)
        #expect(capturedError.withLock { $0 } != nil)
        #expect(fileManager.fileExists(atPath: sourceURL.path))
    }

    @Test("Transfer failure removes the library-owned staged file")
    func transferFailureRemovesStagedFile() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "InnoNetworkDownloadTransferCleanupTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let blockedDirectoryURL = rootURL.appendingPathComponent("not-a-directory", isDirectory: false)
        try Data("blocking-file".utf8).write(to: blockedDirectoryURL)
        let destinationURL = blockedDirectoryURL.appendingPathComponent("payload.bin", isDirectory: false)
        let stagedURL = rootURL.appendingPathComponent("staged-download.tmp", isDirectory: false)
        try Data("staged-payload".utf8).write(to: stagedURL)

        let configuration = DownloadConfiguration.default
        let persistence = DownloadTaskPersistence(store: InMemoryDownloadTaskStore())
        let coordinator = DownloadTransferCoordinator(
            session: StubDownloadURLSession(),
            runtimeRegistry: DownloadRuntimeRegistry(),
            persistence: persistence,
            eventHub: TaskEventHub(
                policy: configuration.eventDeliveryPolicy,
                metricsReporter: configuration.eventMetricsReporter,
                hubKind: .downloadTask
            ),
            lifecycleGate: DownloadLifecycleGate()
        )
        let task = DownloadTask(
            url: URL(string: "https://example.invalid/payload.bin")!,
            destinationURL: destinationURL
        )
        _ = try await persistence.beginStart(
            id: task.id,
            url: task.url,
            destinationURL: task.destinationURL,
            mode: .initial,
            retryCount: 0,
            totalRetryCount: 0
        )
        await task.updateState(.waiting)
        await task.updateState(.downloading)

        await #expect(throws: (any Error).self) {
            try await coordinator.completeDownload(task: task, temporaryLocation: stagedURL)
        }

        #expect(!fileManager.fileExists(atPath: stagedURL.path))
        #expect(await task.state != .completed)
    }

    @Test("Unknown-task completion removes the library-owned staged file")
    func unknownTaskCompletionRemovesStagedFile() async throws {
        let fileManager = FileManager.default
        let stagedURL = fileManager.temporaryDirectory.appendingPathComponent(
            "download-unknown-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        try Data("orphan".utf8).write(to: stagedURL)
        defer { try? fileManager.removeItem(at: stagedURL) }
        let harness = try StubDownloadHarness(label: "completion-unknown-task")

        await harness.injectCompletion(taskIdentifier: Int.max, location: stagedURL)

        #expect(fileManager.fileExists(atPath: stagedURL.path) == false)
        await harness.manager.shutdown()
    }

    @Test("Completion yielded after stream termination removes its staged file")
    func terminatedStreamCompletionRemovesStagedFile() async throws {
        let fileManager = FileManager.default
        let stagedURL = fileManager.temporaryDirectory.appendingPathComponent(
            "download-terminated-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        try Data("orphan".utf8).write(to: stagedURL)
        defer { try? fileManager.removeItem(at: stagedURL) }
        let harness = try StubDownloadHarness(label: "completion-terminated-stream")
        await harness.manager.shutdown()

        harness.injectDelegateCompletion(taskIdentifier: Int.max, location: stagedURL)

        #expect(fileManager.fileExists(atPath: stagedURL.path) == false)
    }

    @Test("Journal keys are deterministic SHA-256 values")
    func journalKeysAreDeterministicAndDistinct() throws {
        let first = try DownloadCompletionStager.stagingKey(forTaskID: "task-a")
        let repeated = try DownloadCompletionStager.stagingKey(forTaskID: "task-a")
        let different = try DownloadCompletionStager.stagingKey(forTaskID: "task-b")

        #expect(first == repeated)
        #expect(first != different)
        #expect(first.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
    }

    @Test("Empty task ids and missing request URLs fail without consuming the source")
    func invalidJournalIdentityFailsClosed() throws {
        let fixture = try makeCompletionJournalFixture(label: "invalid-identity")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let stager = DownloadCompletionStager(directoryURL: fixture.stagingDirectoryURL)

        #expect(throws: DownloadCompletionStagingError.invalidTaskID) {
            _ = try stager.stage(
                fixture.sourceURL,
                taskID: " \n ",
                originalRequestURL: completionOriginalURL,
                currentRequestURL: completionCurrentURL
            )
        }
        #expect(throws: DownloadCompletionStagingError.missingOriginalRequestURL) {
            _ = try stager.stage(
                fixture.sourceURL,
                taskID: "missing-original",
                originalRequestURL: nil,
                currentRequestURL: completionCurrentURL
            )
        }
        #expect(throws: DownloadCompletionStagingError.missingCurrentRequestURL) {
            _ = try stager.stage(
                fixture.sourceURL,
                taskID: "missing-current",
                originalRequestURL: completionOriginalURL,
                currentRequestURL: nil
            )
        }

        #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    }

    @Test("Path-like task ids stay inside the canonical staging root")
    func pathLikeTaskIDCannotEscapeStagingRoot() throws {
        let fixture = try makeCompletionJournalFixture(label: "path-containment")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let stager = DownloadCompletionStager(directoryURL: fixture.stagingDirectoryURL)
        let taskID = "../../outside/\(UUID().uuidString)"

        let completion = try stager.stage(
            fixture.sourceURL,
            taskID: taskID,
            originalRequestURL: completionOriginalURL,
            currentRequestURL: completionCurrentURL
        )
        let canonicalRoot = fixture.stagingDirectoryURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL

        #expect(completion.manifest.taskID == taskID)
        #expect(completion.payloadURL.deletingLastPathComponent() == canonicalRoot)
        #expect(completion.manifestURL.deletingLastPathComponent() == canonicalRoot)
        #expect(!completion.payloadURL.lastPathComponent.contains("outside"))
        #expect(!completion.manifestURL.lastPathComponent.contains("outside"))

        let forgedCompletion = StagedCompletion(
            manifest: completion.manifest,
            payloadURL: fixture.rootURL.appendingPathComponent("outside.payload"),
            manifestURL: completion.manifestURL
        )
        #expect(throws: DownloadCompletionStagingError.artifactEscapesStagingRoot) {
            try stager.validate(forgedCompletion)
        }
    }

    @Test("Symlink, directory, and special-file sources are rejected")
    func nonRegularSourcesAreRejected() throws {
        let fileManager = FileManager.default
        let fixture = try makeCompletionJournalFixture(label: "source-types")
        defer { try? fileManager.removeItem(at: fixture.rootURL) }
        let stager = DownloadCompletionStager(directoryURL: fixture.stagingDirectoryURL)
        let symlinkURL = fixture.sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("source-link")
        let directoryURL = fixture.sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("source-directory", isDirectory: true)
        let fifoURL = fixture.sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("source-fifo")
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: fixture.sourceURL)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        let fifoResult = fifoURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.mkfifo(path, S_IRUSR | S_IWUSR)
        }
        #expect(fifoResult == 0)

        #expect(throws: DownloadCompletionStagingError.sourceIsSymbolicLink) {
            _ = try stager.stage(
                symlinkURL,
                taskID: "symlink",
                originalRequestURL: completionOriginalURL,
                currentRequestURL: completionCurrentURL
            )
        }
        #expect(throws: DownloadCompletionStagingError.sourceIsDirectory) {
            _ = try stager.stage(
                directoryURL,
                taskID: "directory",
                originalRequestURL: completionOriginalURL,
                currentRequestURL: completionCurrentURL
            )
        }
        #expect(throws: DownloadCompletionStagingError.sourceIsNotRegularFile) {
            _ = try stager.stage(
                fifoURL,
                taskID: "fifo",
                originalRequestURL: completionOriginalURL,
                currentRequestURL: completionCurrentURL
            )
        }
    }

    @Test("Existing collisions and incomplete entries are never overwritten")
    func existingJournalArtifactsFailClosed() throws {
        let fileManager = FileManager.default
        let fixture = try makeCompletionJournalFixture(label: "existing-artifacts")
        defer { try? fileManager.removeItem(at: fixture.rootURL) }
        let stager = DownloadCompletionStager(directoryURL: fixture.stagingDirectoryURL)
        let taskID = "target-task"
        let key = try DownloadCompletionStager.stagingKey(forTaskID: taskID)
        let urls = try stager.artifactURLs(forKey: key)
        let collidingManifest = StagedCompletion.Manifest(
            taskID: "different-task",
            originalRequestURL: completionOriginalURL,
            currentRequestURL: completionCurrentURL,
            expectedByteCount: Int64(fixture.payload.count),
            key: key
        )
        let collidingData = try JSONEncoder().encode(collidingManifest)
        try collidingData.write(to: urls.manifestURL)

        #expect(throws: DownloadCompletionStagingError.manifestTaskIDCollision(key)) {
            _ = try stager.stage(
                fixture.sourceURL,
                taskID: taskID,
                originalRequestURL: completionOriginalURL,
                currentRequestURL: completionCurrentURL
            )
        }
        #expect(try Data(contentsOf: urls.manifestURL) == collidingData)
        #expect(fileManager.fileExists(atPath: fixture.sourceURL.path))

        try stager.cleanupArtifacts(forKey: key)
        let incompletePayload = Data("existing-incomplete-payload".utf8)
        try incompletePayload.write(to: urls.payloadURL)

        #expect(throws: DownloadCompletionStagingError.artifactsAlreadyExist(key)) {
            _ = try stager.stage(
                fixture.sourceURL,
                taskID: taskID,
                originalRequestURL: completionOriginalURL,
                currentRequestURL: completionCurrentURL
            )
        }
        #expect(try Data(contentsOf: urls.payloadURL) == incompletePayload)
        #expect(fileManager.fileExists(atPath: fixture.sourceURL.path))
    }

    @Test("A valid journal round-trips and survives the legacy stale sweep")
    func validJournalRoundTrips() throws {
        let fileManager = FileManager.default
        let fixture = try makeCompletionJournalFixture(label: "round-trip")
        defer { try? fileManager.removeItem(at: fixture.rootURL) }
        let stager = DownloadCompletionStager(directoryURL: fixture.stagingDirectoryURL)

        let completion = try stager.stage(
            fixture.sourceURL,
            taskID: "round-trip-task",
            originalRequestURL: completionOriginalURL,
            currentRequestURL: completionCurrentURL
        )
        stager.removeStaleFiles()
        let keys = try stager.enumerateArtifactKeys()
        let loaded = try stager.load(forKey: completion.manifest.key)

        #expect(keys == [completion.manifest.key])
        #expect(loaded == completion)
        #expect(loaded.manifest.expectedByteCount == Int64(fixture.payload.count))
        #expect(try Data(contentsOf: loaded.payloadURL) == fixture.payload)
        #expect(fileManager.fileExists(atPath: loaded.manifestURL.path))
        try stager.validate(loaded)
    }

    @Test("Journal cleanup is bounded to exact task-owned artifacts")
    func journalCleanupIsBounded() throws {
        let fileManager = FileManager.default
        let fixture = try makeCompletionJournalFixture(label: "bounded-cleanup")
        defer { try? fileManager.removeItem(at: fixture.rootURL) }
        let stager = DownloadCompletionStager(directoryURL: fixture.stagingDirectoryURL)
        let completion = try stager.stage(
            fixture.sourceURL,
            taskID: "bounded-cleanup-task",
            originalRequestURL: completionOriginalURL,
            currentRequestURL: completionCurrentURL
        )
        let unrelatedURL = fixture.stagingDirectoryURL.appendingPathComponent("keep-me.txt")
        let outsideTargetURL = fixture.rootURL.appendingPathComponent("outside-target.bin")
        try Data("unrelated".utf8).write(to: unrelatedURL)
        try Data("outside".utf8).write(to: outsideTargetURL)

        try stager.cleanup(completion)

        #expect(!fileManager.fileExists(atPath: completion.payloadURL.path))
        #expect(!fileManager.fileExists(atPath: completion.manifestURL.path))
        #expect(fileManager.fileExists(atPath: unrelatedURL.path))
        #expect(fileManager.fileExists(atPath: outsideTargetURL.path))

        try fileManager.createSymbolicLink(
            at: completion.payloadURL,
            withDestinationURL: outsideTargetURL
        )
        try stager.cleanupArtifacts(forKey: completion.manifest.key)

        #expect(!fileManager.fileExists(atPath: completion.payloadURL.path))
        #expect(fileManager.fileExists(atPath: outsideTargetURL.path))
        #expect(try stager.enumerateArtifactKeys().isEmpty)
    }

    @Test("A policy-rejected journal is cleaned and does not block manual retry")
    func rejectedJournalReleasesAttemptAdmission() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "InnoNetworkRejectedCompletion-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: rootURL) }
        let retryStub = StubDownloadURLTask()
        let harness = try StubDownloadHarness(
            maxRetryCount: 0,
            maxTotalRetries: 0,
            label: "rejected-journal",
            persistenceBaseDirectoryURL: rootURL,
            prequeuedStubs: [retryStub]
        )
        let task = await harness.startDownload()
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        let temporaryURL = rootURL.appendingPathComponent("download.tmp")
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("rejected journal".utf8).write(to: temporaryURL)
        let rejectedURL = URL(string: "http://unsafe.example.invalid/file.zip")!
        let completion = try harness.completionStager.stage(
            temporaryURL,
            taskID: task.id,
            originalRequestURL: task.url,
            currentRequestURL: rejectedURL
        )
        harness.completionAdmissionGate.registerJournal(taskID: task.id)

        await harness.manager.handleCompletion(
            taskIdentifier: taskIdentifier,
            originalRequestURL: task.url,
            currentRequestURL: rejectedURL,
            payload: .journaled(completion),
            error: nil
        )

        #expect(await task.state == .failed)
        #expect(try harness.completionStager.enumerateArtifactKeys().isEmpty)
        await harness.manager.retry(task)
        #expect(await task.state == .downloading)
        #expect(retryStub.resumeCount == 1)

        await harness.manager.cancel(task)
        await harness.manager.shutdown()
    }
}

#if canImport(Darwin)
private func completionStagingBackupExclusionIsApplied(to url: URL) throws -> Bool {
    #if os(macOS)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let extendedAttributesKey = FileAttributeKey(rawValue: "NSFileExtendedAttributes")
    let extendedAttributes = attributes[extendedAttributesKey] as? [String: Data]
    return extendedAttributes?["com.apple.metadata:com_apple_backup_excludeItem"] != nil
    #else
    return try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    #endif
}
#endif


private func enqueueCompletionWithoutInstallingHandler(location: URL) {
    let callbacks = DownloadSessionDelegateCallbacks()
    callbacks.handleCompletion(taskIdentifier: 1, location: location, error: nil)
}

private let completionOriginalURL = URL(string: "https://example.invalid/original.bin")!
private let completionCurrentURL = URL(string: "https://cdn.example.invalid/current.bin")!

private struct CompletionJournalFixture {
    let rootURL: URL
    let stagingDirectoryURL: URL
    let sourceURL: URL
    let payload: Data
}

private func makeCompletionJournalFixture(label: String) throws -> CompletionJournalFixture {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
        "InnoNetworkDownloadCompletionJournal-\(label)-\(UUID().uuidString)",
        isDirectory: true
    )
    let sourceDirectoryURL = rootURL.appendingPathComponent("URLSession", isDirectory: true)
    let stagingDirectoryURL = rootURL.appendingPathComponent("Staging", isDirectory: true)
    let sourceURL = sourceDirectoryURL.appendingPathComponent("download.tmp")
    let payload = Data("journal-payload-\(label)".utf8)
    try fileManager.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
    try payload.write(to: sourceURL)
    return CompletionJournalFixture(
        rootURL: rootURL,
        stagingDirectoryURL: stagingDirectoryURL,
        sourceURL: sourceURL,
        payload: payload
    )
}
