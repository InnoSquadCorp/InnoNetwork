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
        #expect(config.allowsCellularAccess == true)
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
        
        await task.updateState(.failed)
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
        let config = DownloadConfiguration(maxConnectionsPerHost: 5)
        let manager = try DownloadManager(configuration: config)
        
        #expect((await manager.allTasks()).isEmpty)
    }
    
    @Test("Download task is created and tracked")
    func downloadCreation() async throws {
        let config = DownloadConfiguration(sessionIdentifier: "test.download.\(UUID().uuidString)")
        let manager = try DownloadManager(configuration: config)
        
        let url = URL(string: "https://example.com/file.zip")!
        let destination = URL(fileURLWithPath: "/tmp/test-file.zip")
        
        let task = await manager.download(url: url, to: destination)
        
        #expect(task.url == url)
        #expect(task.destinationURL == destination)
        #expect((await manager.allTasks()).contains(task))
        
        await manager.cancel(task)
    }
    
    @Test("Task can be cancelled")
    func cancelTask() async throws {
        let config = DownloadConfiguration(sessionIdentifier: "test.cancel.\(UUID().uuidString)")
        let manager = try DownloadManager(configuration: config)
        
        let url = URL(string: "https://example.com/file.zip")!
        let destination = URL(fileURLWithPath: "/tmp/test-file.zip")
        
        let task = await manager.download(url: url, to: destination)
        await manager.cancel(task)
        
        #expect(await task.state == .cancelled)
        #expect((await manager.allTasks()).isEmpty)
    }
    
    @Test("All tasks can be cancelled")
    func cancelAllTasks() async throws {
        let config = DownloadConfiguration(sessionIdentifier: "test.cancelall.\(UUID().uuidString)")
        let manager = try DownloadManager(configuration: config)
        
        let url1 = URL(string: "https://example.com/file1.zip")!
        let url2 = URL(string: "https://example.com/file2.zip")!
        let dest1 = URL(fileURLWithPath: "/tmp/test-file1.zip")
        let dest2 = URL(fileURLWithPath: "/tmp/test-file2.zip")
        
        _ = await manager.download(url: url1, to: dest1)
        _ = await manager.download(url: url2, to: dest2)
        
        #expect((await manager.allTasks()).count == 2)
        
        await manager.cancelAll()
        
        #expect((await manager.allTasks()).isEmpty)
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

    private func clearPersistence(sessionIdentifier: String, baseDirectoryURL: URL) async {
        let persistence = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )
        await persistence.prune(keeping: [])
    }

    @Test("Persisted tasks can be restored after actor recreation")
    func persistenceRoundTrip() async {
        let sessionIdentifier = "test.persistence.\(UUID().uuidString)"
        let baseDirectoryURL = makeBaseDirectoryURL()
        await clearPersistence(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)

        let taskID = "task-\(UUID().uuidString)"
        let url = URL(string: "https://example.com/file.zip")!
        let destinationURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")

        let writer = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )
        await writer.upsert(id: taskID, url: url, destinationURL: destinationURL)

        let reader = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )
        let restored = await reader.record(forID: taskID)

        #expect(restored?.id == taskID)
        #expect(restored?.url == url)
        #expect(restored?.destinationURL == destinationURL)
        await clearPersistence(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)
    }

    @Test("Prune removes stale task records")
    func pruneRemovesStaleRecords() async {
        let sessionIdentifier = "test.persistence.prune.\(UUID().uuidString)"
        let baseDirectoryURL = makeBaseDirectoryURL()
        await clearPersistence(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)

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
        await persistence.upsert(id: keptID, url: keptURL, destinationURL: keptDestination)
        await persistence.upsert(id: removedID, url: removedURL, destinationURL: removedDestination)

        await persistence.prune(keeping: [keptID])

        #expect(await persistence.record(forID: keptID) != nil)
        #expect(await persistence.record(forID: removedID) == nil)
        await clearPersistence(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)
    }

    @Test("restore metadata remains keyed by task id even when URLs are duplicated")
    func restoreMetadataIsTaskIDBased() async {
        let sessionIdentifier = "test.persistence.duplicate-url.\(UUID().uuidString)"
        let baseDirectoryURL = makeBaseDirectoryURL()
        await clearPersistence(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)

        let sharedURL = URL(string: "https://example.com/shared.zip")!
        let firstDestination = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-first.zip")
        let secondDestination = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-second.zip")

        let persistence = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectoryURL
        )
        await persistence.upsert(id: "task-1", url: sharedURL, destinationURL: firstDestination)
        await persistence.upsert(id: "task-2", url: sharedURL, destinationURL: secondDestination)

        #expect(await persistence.record(forID: "task-1")?.destinationURL == firstDestination)
        #expect(await persistence.record(forID: "task-2")?.destinationURL == secondDestination)
        await clearPersistence(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)
    }

    @Test("Corrupted persistence file is quarantined and store restarts cleanly")
    func corruptedStoreIsQuarantined() async throws {
        let sessionIdentifier = "test.persistence.corrupted.\(UUID().uuidString)"
        let baseDirectoryURL = makeBaseDirectoryURL()
        let storeDirectory = sessionDirectoryURL(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)
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
    func appendLogPreservesConcurrentUpdates() async {
        let sessionIdentifier = "test.persistence.concurrent.\(UUID().uuidString)"
        let baseDirectoryURL = makeBaseDirectoryURL()
        await clearPersistence(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)

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
        _ = await (writeA, writeB)

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
            await persistence.upsert(
                id: "task-\(index)",
                url: URL(string: "https://example.com/\(index).zip")!,
                destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-\(index).zip")
            )
        }

        let storeDirectory = sessionDirectoryURL(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)
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
        await writer.upsert(
            id: "task-valid",
            url: URL(string: "https://example.com/valid.zip")!,
            destinationURL: destinationURL
        )

        let storeDirectory = sessionDirectoryURL(sessionIdentifier: sessionIdentifier, baseDirectoryURL: baseDirectoryURL)
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
