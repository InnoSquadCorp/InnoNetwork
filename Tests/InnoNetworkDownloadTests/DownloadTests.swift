import Foundation
import Testing

@testable import InnoNetworkDownload

@Suite("Download Configuration Tests")
struct DownloadConfigurationTests {

    @Test("Default configuration has expected values")
    func defaultConfiguration() {
        let config = DownloadConfiguration.default

        #expect(config.maxConnectionsPerHost == 3)
        #expect(config.maxRetryCount == 3)
        #expect(config.maxTotalRetries == 3)
        #expect(config.retryDelay == 1.0)
        // Cellular is opt-in in 4.0.x — see `cellularEnabled()`.
        #expect(config.allowsCellularAccess == false)
    }

    @Test("cellularEnabled() returns a copy with cellular access on")
    func cellularEnabledFlipsAllowsCellularAccess() {
        let base = DownloadConfiguration.safeDefaults(sessionIdentifier: "test.cellular.opt-in")
        #expect(base.allowsCellularAccess == false)
        let cellular = base.cellularEnabled()
        #expect(cellular.allowsCellularAccess == true)
        // Other fields should be preserved unchanged.
        #expect(cellular.sessionIdentifier == base.sessionIdentifier)
        #expect(cellular.maxRetryCount == base.maxRetryCount)
    }

    @Test("persistenceBaseDirectoryURL flows through the AdvancedBuilder")
    func persistenceBaseDirectoryURLRoundtrips() {
        let custom = URL(fileURLWithPath: "/tmp/inno-test-cache", isDirectory: true)
        let config = DownloadConfiguration.advanced { builder in
            builder.persistenceBaseDirectoryURL = custom
        }
        #expect(config.persistenceBaseDirectoryURL == custom)
    }

    @Test("safeDefaults matches default configuration")
    func safeDefaultsMatchesDefault() {
        let config = DownloadConfiguration.safeDefaults()
        let defaultConfig = DownloadConfiguration.default

        #expect(config.maxConnectionsPerHost == defaultConfig.maxConnectionsPerHost)
        #expect(config.maxRetryCount == defaultConfig.maxRetryCount)
        #expect(config.maxTotalRetries == defaultConfig.maxTotalRetries)
        #expect(config.retryDelay == defaultConfig.retryDelay)
    }

    @Test("advanced builder can override high-tuning configuration")
    func advancedBuilderOverrides() {
        let config = DownloadConfiguration.advanced {
            $0.maxConnectionsPerHost = 9
            $0.waitsForNetworkChanges = true
            $0.networkChangeTimeout = 30
        }

        #expect(config.maxConnectionsPerHost == 9)
        #expect(config.waitsForNetworkChanges == true)
        #expect(config.networkChangeTimeout == 30)
    }

    @Test("Custom configuration is applied correctly")
    func customConfiguration() {
        let config = DownloadConfiguration(
            maxConnectionsPerHost: 5,
            maxRetryCount: 5,
            maxTotalRetries: 8,
            retryDelay: 2.0,
            allowsCellularAccess: false
        )

        #expect(config.maxConnectionsPerHost == 5)
        #expect(config.maxRetryCount == 5)
        #expect(config.maxTotalRetries == 8)
        #expect(config.retryDelay == 2.0)
        #expect(config.allowsCellularAccess == false)
    }

    @Test("URLSessionConfiguration is created correctly")
    func urlSessionConfiguration() {
        let config = DownloadConfiguration(
            maxConnectionsPerHost: 4,
            allowsCellularAccess: false,
            sessionIdentifier: "test.session"
        )

        let sessionConfig = config.makeURLSessionConfiguration()

        #expect(sessionConfig.identifier == "test.session")
        #expect(sessionConfig.allowsCellularAccess == false)
        #expect(sessionConfig.httpMaximumConnectionsPerHost == 4)
    }

    @Test("Negative values are clamped to safe bounds")
    func negativeValueClamping() {
        let config = DownloadConfiguration(
            maxConnectionsPerHost: -1,
            maxRetryCount: -2,
            maxTotalRetries: -3,
            retryDelay: -0.5,
            timeoutForRequest: -10,
            timeoutForResource: -20
        )

        #expect(config.maxConnectionsPerHost == 1)
        #expect(config.maxRetryCount == 0)
        #expect(config.maxTotalRetries == 0)
        #expect(config.retryDelay == 0)
        #expect(config.timeoutForRequest == 0)
        #expect(config.timeoutForResource == 0)
    }
}


@Suite("Download Task Tests")
struct DownloadTaskTests {

    @Test("Task is created with correct initial state")
    func initialState() async {
        let url = URL(string: "https://example.com/file.zip")!
        let destination = URL(fileURLWithPath: "/tmp/file.zip")
        let task = DownloadTask(url: url, destinationURL: destination)

        #expect(await task.state == .idle)
        #expect(await task.progress.fractionCompleted == 0)
        #expect(await task.retryCount == 0)
        #expect(await task.totalRetryCount == 0)
        #expect(await task.error == nil)
    }

    @Test("Task state can be updated")
    func stateUpdate() async {
        let url = URL(string: "https://example.com/file.zip")!
        let destination = URL(fileURLWithPath: "/tmp/file.zip")
        let task = DownloadTask(url: url, destinationURL: destination)

        await task.updateState(.downloading)
        #expect(await task.state == .downloading)

        await task.updateState(.paused)
        #expect(await task.state == .paused)
    }

    @Test("Task progress is updated correctly")
    func progressUpdate() async {
        let url = URL(string: "https://example.com/file.zip")!
        let destination = URL(fileURLWithPath: "/tmp/file.zip")
        let task = DownloadTask(url: url, destinationURL: destination)

        let progress = DownloadProgress(
            bytesWritten: 1024,
            totalBytesWritten: 5120,
            totalBytesExpectedToWrite: 10240
        )
        await task.updateProgress(progress)

        #expect(await task.progress.totalBytesWritten == 5120)
        #expect(await task.progress.fractionCompleted == 0.5)
        #expect(await task.progress.percentCompleted == 50)
    }

    @Test("Task can be reset")
    func taskReset() async {
        let url = URL(string: "https://example.com/file.zip")!
        let destination = URL(fileURLWithPath: "/tmp/file.zip")
        let task = DownloadTask(url: url, destinationURL: destination)

        await task.restoreState(.failed)
        await task.setError(.maxRetriesExceeded)
        _ = await task.incrementRetryCount()
        _ = await task.incrementTotalRetryCount()

        await task.reset()

        #expect(await task.state == .idle)
        #expect(await task.retryCount == 0)
        #expect(await task.totalRetryCount == 0)
        #expect(await task.error == nil)
    }

    @Test("Download lifecycle helper documents legal transitions")
    func stateTransitionModel() {
        #expect(DownloadState.idle.nextStates == [.waiting, .downloading, .cancelled])
        #expect(DownloadState.idle.canTransition(to: .waiting))
        #expect(DownloadState.waiting.canTransition(to: .downloading))
        #expect(DownloadState.downloading.canTransition(to: .completed))
        #expect(DownloadState.failed.canTransition(to: .idle))
        #expect(!DownloadState.completed.canTransition(to: .downloading))
        #expect(DownloadState.completed.isTerminal)
        #expect(!DownloadState.waiting.isTerminal)
    }

    @Test("restoreState bypasses transition validation for restore/test injection")
    func restoreStateBypassesValidation() async {
        let url = URL(string: "https://example.com/file.zip")!
        let destination = URL(fileURLWithPath: "/tmp/file.zip")
        let task = DownloadTask(url: url, destinationURL: destination)

        // .idle → .paused is not a documented transition, but restoreState
        // is the explicit escape hatch for state restoration on app launch.
        await task.restoreState(.paused)
        #expect(await task.state == .paused)
    }
}


@Suite("Download Progress Tests")
struct DownloadProgressTests {

    @Test("Fraction completed is calculated correctly")
    func fractionCompleted() {
        let progress = DownloadProgress(
            bytesWritten: 100,
            totalBytesWritten: 500,
            totalBytesExpectedToWrite: 1000
        )

        #expect(progress.fractionCompleted == 0.5)
    }

    @Test("Percent completed is calculated correctly")
    func percentCompleted() {
        let progress = DownloadProgress(
            bytesWritten: 100,
            totalBytesWritten: 750,
            totalBytesExpectedToWrite: 1000
        )

        #expect(progress.percentCompleted == 75)
    }

    @Test("Zero expected bytes returns zero progress")
    func zeroExpected() {
        let progress = DownloadProgress(
            bytesWritten: 0,
            totalBytesWritten: 0,
            totalBytesExpectedToWrite: 0
        )

        #expect(progress.fractionCompleted == 0)
        #expect(progress.percentCompleted == 0)
    }
}


@Suite("Download Error Tests")
struct DownloadErrorTests {

    @Test("Error descriptions are meaningful")
    func errorDescriptions() {
        #expect(DownloadError.cancelled.errorDescription?.contains("cancelled") == true)
        #expect(DownloadError.maxRetriesExceeded.errorDescription?.contains("retry") == true)
        #expect(DownloadError.invalidURL("test").errorDescription?.contains("test") == true)
    }
}


@Suite("Download Manager Tests")
struct DownloadManagerTests {

    @Test("Manager can be created with custom configuration")
    func customManager() async throws {
        // Use a unique session identifier so this test does not race against
        // any sibling test that may have already claimed an identifier in the
        // same process.
        let config = DownloadConfiguration(
            maxConnectionsPerHost: 5,
            sessionIdentifier: "test.custom-manager.\(UUID().uuidString)"
        )
        let manager = try DownloadManager(configuration: config)

        #expect((await manager.allTasks()).isEmpty)
    }

    @Test("Download task is created and tracked")
    func downloadCreation() async throws {
        let harness = try StubDownloadHarness(label: "manager-download")

        let url = URL(string: "https://example.com/file.zip")!
        let destination = URL(fileURLWithPath: "/tmp/test-file.zip")

        let task = await harness.startDownload(url: url, destinationURL: destination)

        #expect(task.url == url)
        #expect(task.destinationURL == destination)
        #expect((await harness.manager.allTasks()).contains(task))

        await harness.manager.cancel(task)
    }

    @Test("Task can be cancelled")
    func cancelTask() async throws {
        let harness = try StubDownloadHarness(label: "manager-cancel")

        let url = URL(string: "https://example.com/file.zip")!
        let destination = URL(fileURLWithPath: "/tmp/test-file.zip")

        let task = await harness.startDownload(url: url, destinationURL: destination)
        await harness.manager.cancel(task)

        #expect(await task.state == .cancelled)
        #expect(await waitForTaskCount(manager: harness.manager, expectedCount: 0))
    }

    @Test("All tasks can be cancelled")
    func cancelAllTasks() async throws {
        let harness = try StubDownloadHarness(label: "manager-cancelall")
        harness.stubSession.enqueue(StubDownloadURLTask())

        let url1 = URL(string: "https://example.com/file1.zip")!
        let url2 = URL(string: "https://example.com/file2.zip")!
        let dest1 = URL(fileURLWithPath: "/tmp/test-file1.zip")
        let dest2 = URL(fileURLWithPath: "/tmp/test-file2.zip")

        _ = await harness.startDownload(url: url1, destinationURL: dest1)
        _ = await harness.startDownload(url: url2, destinationURL: dest2)

        #expect((await harness.manager.allTasks()).count == 2)

        await harness.manager.cancelAll()

        #expect(await waitForTaskCount(manager: harness.manager, expectedCount: 0))
    }

    @Test("Duplicate session identifiers surface a recoverable initialization error")
    func duplicateSessionIdentifierThrows() throws {
        let identifier = "test.duplicate.\(UUID().uuidString)"
        let first = try DownloadManager(
            configuration: DownloadConfiguration(sessionIdentifier: identifier)
        )
        _ = first

        #expect(
            throws: DownloadManagerError.duplicateSessionIdentifier(identifier),
            performing: {
                _ = try DownloadManager(
                    configuration: DownloadConfiguration(sessionIdentifier: identifier)
                )
            }
        )
    }

    private func waitForTaskCount(manager: DownloadManager, expectedCount: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if await manager.allTasks().count == expectedCount {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}


actor DownloadStateRecorder {
    private var states: [DownloadState] = []

    func record(_ state: DownloadState) {
        states.append(state)
    }

    func snapshot() -> [DownloadState] {
        states
    }

    func count() -> Int {
        states.count
    }
}

@Suite("Download Callback Tests")
struct DownloadCallbackTests {
    private var runIntegrationTests: Bool {
        ProcessInfo.processInfo.environment["INNONETWORK_RUN_INTEGRATION_TESTS"] == "1"
    }

    @Test("State callback receives waiting and downloading immediately after start")
    func stateCallbackOrdering() async throws {
        guard runIntegrationTests else { return }
        let config = DownloadConfiguration(sessionIdentifier: "test.callback.\(UUID().uuidString)")
        let manager = try DownloadManager(configuration: config)
        let recorder = DownloadStateRecorder()

        await manager.setOnStateChangedHandler { _, state in
            await recorder.record(state)
        }

        let task = await manager.download(
            url: URL(string: "https://example.com/file.zip")!,
            to: URL(fileURLWithPath: "/tmp/test-callback-\(UUID().uuidString).zip")
        )

        let received = await waitForStates(recorder: recorder, expectedCount: 2)
        #expect(received)

        let firstTwoStates = Array((await recorder.snapshot()).prefix(2))
        #expect(firstTwoStates == [.waiting, .downloading])

        await manager.cancel(task)
    }

    private func waitForStates(recorder: DownloadStateRecorder, expectedCount: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if await recorder.count() >= expectedCount {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

}

@Suite("Download Task Persistence Tests")
struct DownloadTaskPersistenceTests {
    private func makeBaseDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("InnoNetworkDownloadTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func sessionDirectoryURL(sessionIdentifier: String, baseDirectoryURL: URL) -> URL {
        baseDirectoryURL
            .appendingPathComponent("InnoNetworkDownload", isDirectory: true)
            .appendingPathComponent(sessionIdentifier, isDirectory: true)
    }

    private func clearPersistence(sessionIdentifier: String, baseDirectoryURL: URL) async throws {
        let persistence = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )
        try await persistence.prune(keeping: [])
    }

    @Test("Persisted tasks can be restored after actor recreation")
    func persistenceRoundTrip() async throws {
        let sessionIdentifier = "test.persistence.\(UUID().uuidString)"
        let baseDirectoryURL = makeBaseDirectoryURL()
        try await clearPersistence(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)

        let taskID = "task-\(UUID().uuidString)"
        let url = URL(string: "https://example.com/file.zip")!
        let destinationURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")

        let writer = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )
        try await writer.upsert(id: taskID, url: url, destinationURL: destinationURL)

        let reader = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )
        let restored = await reader.record(forID: taskID)

        #expect(restored?.id == taskID)
        #expect(restored?.url == url)
        #expect(restored?.destinationURL == destinationURL)
        try await clearPersistence(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)
    }

    @Test("Prune removes stale task records")
    func pruneRemovesStaleRecords() async throws {
        let sessionIdentifier = "test.persistence.prune.\(UUID().uuidString)"
        let baseDirectoryURL = makeBaseDirectoryURL()
        try await clearPersistence(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)

        let keptID = "task-kept"
        let removedID = "task-removed"
        let keptURL = URL(string: "https://example.com/kept.zip")!
        let removedURL = URL(string: "https://example.com/removed.zip")!
        let keptDestination = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-kept.zip")
        let removedDestination = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-removed.zip")

        let persistence = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )
        try await persistence.upsert(id: keptID, url: keptURL, destinationURL: keptDestination)
        try await persistence.upsert(id: removedID, url: removedURL, destinationURL: removedDestination)

        try await persistence.prune(keeping: [keptID])

        #expect(await persistence.record(forID: keptID) != nil)
        #expect(await persistence.record(forID: removedID) == nil)
        try await clearPersistence(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)
    }

    @Test("Append log prune uses locked disk state from other store instances")
    func appendLogPruneSeesRecordsWrittenByOtherInstances() async throws {
        let sessionIdentifier = "test.persistence.prune-cross-instance.\(UUID().uuidString)"
        let baseDirectoryURL = makeBaseDirectoryURL()
        try await clearPersistence(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)

        let keptID = "task-kept"
        let staleID = "task-stale"
        let firstStore = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )
        let secondStore = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )

        try await firstStore.upsert(
            id: keptID,
            url: URL(string: "https://example.com/kept.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-kept.zip")
        )
        try await secondStore.upsert(
            id: staleID,
            url: URL(string: "https://example.com/stale.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-stale.zip")
        )

        try await firstStore.prune(keeping: [keptID])

        let reader = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )
        #expect(await reader.record(forID: keptID) != nil)
        #expect(await reader.record(forID: staleID) == nil)
        try await clearPersistence(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)
    }

    @Test("restore metadata remains keyed by task id even when URLs are duplicated")
    func restoreMetadataIsTaskIDBased() async throws {
        let sessionIdentifier = "test.persistence.duplicate-url.\(UUID().uuidString)"
        let baseDirectoryURL = makeBaseDirectoryURL()
        try await clearPersistence(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)

        let sharedURL = URL(string: "https://example.com/shared.zip")!
        let firstDestination = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-first.zip")
        let secondDestination = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-second.zip")

        let persistence = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )
        try await persistence.upsert(id: "task-1", url: sharedURL, destinationURL: firstDestination)
        try await persistence.upsert(id: "task-2", url: sharedURL, destinationURL: secondDestination)

        #expect(await persistence.record(forID: "task-1")?.destinationURL == firstDestination)
        #expect(await persistence.record(forID: "task-2")?.destinationURL == secondDestination)
        try await clearPersistence(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)
    }

    @Test("Corrupted persistence file is quarantined and store restarts cleanly")
    func corruptedStoreIsQuarantined() async throws {
        let sessionIdentifier = "test.persistence.corrupted.\(UUID().uuidString)"
        let baseDirectoryURL = makeBaseDirectoryURL()
        let storeDirectory = sessionDirectoryURL(
            sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let checkpointURL = storeDirectory.appendingPathComponent("checkpoint.json")
        try Data("not-json".utf8).write(to: checkpointURL)

        let persistence = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )

        #expect(await persistence.allRecords().isEmpty)

        let files = try FileManager.default.contentsOfDirectory(atPath: storeDirectory.path)
        #expect(files.contains(where: { $0.contains(".corrupted-") }))
        #expect(files.contains("checkpoint.json") == false)
    }

    @Test("Append log preserves concurrent updates across store instances")
    func appendLogPreservesConcurrentUpdates() async throws {
        let sessionIdentifier = "test.persistence.concurrent.\(UUID().uuidString)"
        let baseDirectoryURL = makeBaseDirectoryURL()
        try await clearPersistence(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)

        let firstStore = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )
        let secondStore = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )

        async let writeA: Void = firstStore.upsert(
            id: "task-a",
            url: URL(string: "https://example.com/a.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/a-\(UUID().uuidString).zip")
        )
        async let writeB: Void = secondStore.upsert(
            id: "task-b",
            url: URL(string: "https://example.com/b.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/b-\(UUID().uuidString).zip")
        )
        _ = try await (writeA, writeB)

        let reader = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )
        let records = await reader.allRecords()
        #expect(records.count == 2)
    }

    @Test("Append log compacts into checkpoint after threshold")
    func appendLogCompactsAfterThreshold() async throws {
        let sessionIdentifier = "test.persistence.compaction.\(UUID().uuidString)"
        let baseDirectoryURL = makeBaseDirectoryURL()
        let persistence = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )

        for index in 0..<1_000 {
            try await persistence.upsert(
                id: "task-\(index)",
                url: URL(string: "https://example.com/\(index).zip")!,
                destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-\(index).zip")
            )
        }

        let storeDirectory = sessionDirectoryURL(
            sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)
        let checkpointURL = storeDirectory.appendingPathComponent("checkpoint.json")
        let logURL = storeDirectory.appendingPathComponent("events.log")
        #expect(FileManager.default.fileExists(atPath: checkpointURL.path))
        let logData = try Data(contentsOf: logURL)
        #expect(logData.isEmpty)
    }

    @Test("Corrupted append log tail replays valid prefix and quarantines the log")
    func corruptedLogTailReplaysValidPrefix() async throws {
        let sessionIdentifier = "test.persistence.log-tail.\(UUID().uuidString)"
        let baseDirectoryURL = makeBaseDirectoryURL()
        let writer = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )
        let destinationURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-valid.zip")
        try await writer.upsert(
            id: "task-valid",
            url: URL(string: "https://example.com/valid.zip")!,
            destinationURL: destinationURL
        )

        let storeDirectory = sessionDirectoryURL(
            sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)
        let logURL = storeDirectory.appendingPathComponent("events.log")
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        handle.write(Data("not-json\n".utf8))
        try handle.close()

        let reader = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )
        let restored = await reader.record(forID: "task-valid")
        #expect(restored?.destinationURL == destinationURL)

        let files = try FileManager.default.contentsOfDirectory(atPath: storeDirectory.path)
        #expect(files.contains(where: { $0.hasPrefix("events.corrupted-") }))
    }
}


private actor DownloadEventRecorder {
    private var events: [DownloadEvent] = []

    func record(_ event: DownloadEvent) {
        events.append(event)
    }

    func snapshot() -> [DownloadEvent] {
        events
    }
}


@Suite("Download Delegate Ordering Tests")
struct DownloadDelegateOrderingTests {
    @Test("Delegate progress is processed before completion when callbacks arrive in order")
    func delegateProgressPrecedesCompletion() async throws {
        let harness = try StubDownloadHarness(label: "delegate-order")
        let task = await harness.startDownload()
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task
            ))
        let recorder = DownloadEventRecorder()
        _ = await harness.manager.addEventListener(for: task) { event in
            await recorder.record(event)
        }

        let temporaryLocation = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-delegate-order-\(UUID().uuidString).data")
        try Data("payload".utf8).write(to: temporaryLocation)
        defer {
            try? FileManager.default.removeItem(at: temporaryLocation)
            try? FileManager.default.removeItem(at: task.destinationURL)
        }

        harness.injectDelegateProgress(
            taskIdentifier: taskIdentifier,
            bytesWritten: 7,
            totalBytesWritten: 7,
            totalBytesExpectedToWrite: 14
        )
        harness.injectDelegateCompletion(taskIdentifier: taskIdentifier, location: temporaryLocation)

        let completedReceived = await waitForEvent(recorder: recorder) { event in
            if case .completed = event { return true }
            return false
        }
        #expect(completedReceived)

        let events = await recorder.snapshot()
        let progressIndex = events.firstIndex { event in
            if case .progress(let progress) = event {
                return progress.totalBytesWritten == 7
            }
            return false
        }
        let completionIndex = events.firstIndex { event in
            if case .completed = event { return true }
            return false
        }

        #expect(progressIndex != nil)
        #expect(completionIndex != nil)
        if let progressIndex, let completionIndex {
            #expect(progressIndex < completionIndex)
        }
    }

    private func waitForEvent(
        recorder: DownloadEventRecorder,
        timeout: TimeInterval = 2.0,
        predicate: @escaping @Sendable (DownloadEvent) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let events = await recorder.snapshot()
            if events.contains(where: predicate) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}


@Suite("Download Background Completion Tests")
struct DownloadBackgroundCompletionTests {
    @Test("Background completion runs when session finishes before the app registers completion")
    func backgroundCompletionRunsAfterFinishBeforeSetRace() async throws {
        let harness = try StubDownloadHarness(label: "background-completion-race")
        await harness.markBackgroundEventsFinished()

        await confirmation("background completion called") { confirm in
            harness.handleBackgroundSessionCompletion {
                confirm()
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}


@Suite("Download Transfer Coordinator Tests")
struct DownloadTransferCoordinatorTests {
    @Test("Failed replacement preserves an existing destination file")
    func failedReplacementPreservesExistingDestination() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "download-replace-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("payload.bin")
        let existing = Data("existing payload".utf8)
        try existing.write(to: destination)

        let missingTemporaryLocation = directory.appendingPathComponent("missing-\(UUID().uuidString).tmp")
        let runtimeRegistry = DownloadRuntimeRegistry()
        let persistence = DownloadTaskPersistence(store: InMemoryDownloadTaskStore())
        let configuration = DownloadConfiguration.default
        let coordinator = DownloadTransferCoordinator(
            session: StubDownloadURLSession(),
            runtimeRegistry: runtimeRegistry,
            persistence: persistence,
            eventHub: TaskEventHub(
                policy: configuration.eventDeliveryPolicy,
                metricsReporter: configuration.eventMetricsReporter,
                hubKind: .downloadTask
            )
        )
        let task = DownloadTask(
            url: URL(string: "https://example.invalid/payload.bin")!,
            destinationURL: destination
        )

        await #expect(throws: (any Error).self) {
            try await coordinator.completeDownload(task: task, temporaryLocation: missingTemporaryLocation)
        }

        #expect(try Data(contentsOf: destination) == existing)
        #expect(await task.state != .completed)
    }
}


@Suite("Download Persistence Cleanup Tests")
struct DownloadPersistenceCleanupTests {
    @Test("Existing destination is preserved when replacement temp file is missing")
    func existingDestinationIsPreservedWhenReplacementFails() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("innonetwork-download-replace-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("existing.zip")
        try Data("existing-payload".utf8).write(to: destination)
        let missingTemporaryLocation = directory.appendingPathComponent("missing-temp.data")

        let harness = try StubDownloadHarness(
            maxRetryCount: 0,
            maxTotalRetries: 0,
            label: "completion-replace-failure"
        )
        let task = await harness.startDownload(destinationURL: destination)
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task
            ))

        await harness.injectCompletion(taskIdentifier: taskIdentifier, location: missingTemporaryLocation)

        #expect(await task.state == .failed)
        let preservedData = try Data(contentsOf: destination)
        #expect(String(data: preservedData, encoding: .utf8) == "existing-payload")
    }

    @Test("Completed task remains registered when persistence removal fails")
    func completedTaskRemainsRegisteredWhenPersistenceRemovalFails() async throws {
        let harness = try StubDownloadHarness(label: "completion-remove-failure")
        let task = await harness.startDownload()
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task
            ))

        let temporaryLocation = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-remove-failure-\(UUID().uuidString).data")
        try Data("payload".utf8).write(to: temporaryLocation)
        defer {
            try? FileManager.default.removeItem(at: temporaryLocation)
            try? FileManager.default.removeItem(at: task.destinationURL)
        }

        await harness.store.setRemoveFailure(true)
        await harness.injectCompletion(taskIdentifier: taskIdentifier, location: temporaryLocation)

        #expect(await task.state == .completed)
        #expect(await harness.manager.task(withId: task.id) != nil)
        #expect(await harness.persistence.record(forID: task.id) != nil)

        await harness.store.setRemoveFailure(false)
        await harness.manager.cancel(task)
    }

    @Test("Cancelled task remains registered when persistence removal fails")
    func cancelledTaskRemainsRegisteredWhenPersistenceRemovalFails() async throws {
        let harness = try StubDownloadHarness(label: "cancel-remove-failure")
        let task = await harness.startDownload()

        await harness.store.setRemoveFailure(true)
        await harness.manager.cancel(task)

        #expect(await task.state == .cancelled)
        #expect(await harness.manager.task(withId: task.id) != nil)
        #expect(await harness.persistence.record(forID: task.id) != nil)

        await harness.store.setRemoveFailure(false)
        await harness.manager.cancel(task)
        #expect(await harness.manager.task(withId: task.id) == nil)
    }

    @Test("Failed task remains registered when persistence removal fails")
    func failedTaskRemainsRegisteredWhenPersistenceRemovalFails() async throws {
        let harness = try StubDownloadHarness(
            maxRetryCount: 0,
            maxTotalRetries: 0,
            label: "failed-remove-failure"
        )
        let task = await harness.startDownload()
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task
            ))

        await harness.store.setRemoveFailure(true)
        await harness.injectCompletion(
            taskIdentifier: taskIdentifier,
            location: nil,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.networkConnectionLost.rawValue,
                message: "network lost"
            )
        )

        #expect(await task.state == .failed)
        #expect(await harness.manager.task(withId: task.id) != nil)
        #expect(await harness.persistence.record(forID: task.id) != nil)

        await harness.store.setRemoveFailure(false)
        await harness.manager.cancel(task)
    }
}


@Suite("Download Listener Lifecycle Tests")
struct DownloadListenerLifecycleTests {
    private var runIntegrationTests: Bool {
        ProcessInfo.processInfo.environment["INNONETWORK_RUN_INTEGRATION_TESTS"] == "1"
    }

    @Test("Listener persists across retry and receives completion")
    func listenerPersistsAcrossRetryAndCompletion() async throws {
        guard runIntegrationTests else { return }
        let config = DownloadConfiguration(
            maxRetryCount: 1,
            maxTotalRetries: 1,
            retryDelay: 0.0,
            sessionIdentifier: "test.download.listener.retry.\(UUID().uuidString)"
        )
        let manager = try DownloadManager(configuration: config)
        let recorder = DownloadEventRecorder()
        do {
            let destination = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-download-result.zip")
            let task = await manager.download(
                url: URL(string: "https://example.invalid/file.zip")!,
                to: destination
            )
            let _ = await manager.addEventListener(for: task) { event in
                await recorder.record(event)
            }

            let firstTaskIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))
            await injectSyntheticCompletion(
                manager: manager,
                task: task,
                taskIdentifier: firstTaskIdentifier,
                location: nil,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "network lost"
                )
            )

            let retriedTaskIdentifier = try #require(
                await waitForRuntimeTaskIdentifier(
                    manager: manager,
                    task: task,
                    excluding: firstTaskIdentifier
                )
            )

            #expect(await manager.listenerCount(for: task) == 1)

            let temporaryLocation = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-download-temp.data")
            defer { try? FileManager.default.removeItem(at: temporaryLocation) }
            try Data("payload".utf8).write(to: temporaryLocation)
            await injectSyntheticCompletion(
                manager: manager,
                task: task,
                taskIdentifier: retriedTaskIdentifier,
                location: temporaryLocation,
                error: nil
            )

            let completedReceived = await waitForEvent(
                recorder: recorder,
                timeout: 2.0
            ) { event in
                if case .completed(let outputURL) = event {
                    return outputURL == destination
                }
                return false
            }
            #expect(completedReceived)

            #expect(await manager.listenerCount(for: task) == 0)
            #expect(await manager.task(withId: task.id) == nil)

            try? FileManager.default.removeItem(at: destination)
        } catch {
            await manager.cancelAll()
            throw error
        }
        await manager.cancelAll()
    }

    @Test("Terminal failure removes listeners and task runtime")
    func terminalFailureRemovesListeners() async throws {
        guard runIntegrationTests else { return }
        let config = DownloadConfiguration(
            maxRetryCount: 0,
            maxTotalRetries: 0,
            retryDelay: 0.0,
            sessionIdentifier: "test.download.listener.terminal.\(UUID().uuidString)"
        )
        let manager = try DownloadManager(configuration: config)
        let recorder = DownloadEventRecorder()
        do {
            let task = await manager.download(
                url: URL(string: "https://example.invalid/file.zip")!,
                to: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-download-terminal.zip")
            )
            let _ = await manager.addEventListener(for: task) { event in
                await recorder.record(event)
            }

            let taskIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))
            await injectSyntheticCompletion(
                manager: manager,
                task: task,
                taskIdentifier: taskIdentifier,
                location: nil,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "network lost"
                )
            )

            let failedReceived = await waitForEvent(
                recorder: recorder,
                timeout: 2.0
            ) { event in
                if case .failed(.maxRetriesExceeded) = event {
                    return true
                }
                return false
            }
            #expect(failedReceived)

            #expect(await manager.listenerCount(for: task) == 0)
            #expect(await manager.task(withId: task.id) == nil)
        } catch {
            await manager.cancelAll()
            throw error
        }
        await manager.cancelAll()
    }

    private func waitForRuntimeTaskIdentifier(
        manager: DownloadManager,
        task: DownloadTask,
        excluding previousIdentifier: Int? = nil,
        timeout: TimeInterval = 2.0
    ) async -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let identifier = await manager.runtimeTaskIdentifier(for: task) {
                if previousIdentifier == nil || identifier != previousIdentifier {
                    return identifier
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private func waitForEvent(
        recorder: DownloadEventRecorder,
        timeout: TimeInterval,
        predicate: @escaping (DownloadEvent) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let events = await recorder.snapshot()
            if events.contains(where: predicate) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
