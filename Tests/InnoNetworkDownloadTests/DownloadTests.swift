import Foundation
import Testing
@testable import InnoNetworkDownload


@Suite("Download Configuration Tests")
struct DownloadConfigurationTests {
    
    @Test("Default configuration has expected values")
    func defaultConfiguration() {
        let config = DownloadConfiguration.default
        
        #expect(config.maxConcurrentDownloads == 3)
        #expect(config.maxRetryCount == 3)
        #expect(config.maxTotalRetries == 3)
        #expect(config.retryDelay == 1.0)
        #expect(config.allowsCellularAccess == true)
    }
    
    @Test("Custom configuration is applied correctly")
    func customConfiguration() {
        let config = DownloadConfiguration(
            maxConcurrentDownloads: 5,
            maxRetryCount: 5,
            maxTotalRetries: 8,
            retryDelay: 2.0,
            allowsCellularAccess: false
        )
        
        #expect(config.maxConcurrentDownloads == 5)
        #expect(config.maxRetryCount == 5)
        #expect(config.maxTotalRetries == 8)
        #expect(config.retryDelay == 2.0)
        #expect(config.allowsCellularAccess == false)
    }
    
    @Test("URLSessionConfiguration is created correctly")
    func urlSessionConfiguration() {
        let config = DownloadConfiguration(
            maxConcurrentDownloads: 4,
            allowsCellularAccess: false,
            sessionIdentifier: "test.session"
        )
        
        let sessionConfig = config.makeURLSessionConfiguration()
        
        #expect(sessionConfig.identifier == "test.session")
        #expect(sessionConfig.allowsCellularAccess == false)
        #expect(sessionConfig.httpMaximumConnectionsPerHost == 4)
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
    func customManager() async {
        let config = DownloadConfiguration(maxConcurrentDownloads: 5)
        let manager = DownloadManager(configuration: config)
        
        #expect((await manager.allTasks()).isEmpty)
    }
    
    @Test("Download task is created and tracked")
    func downloadCreation() async {
        let config = DownloadConfiguration(sessionIdentifier: "test.download.\(UUID().uuidString)")
        let manager = DownloadManager(configuration: config)
        
        let url = URL(string: "https://example.com/file.zip")!
        let destination = URL(fileURLWithPath: "/tmp/test-file.zip")
        
        let task = await manager.download(url: url, to: destination)
        
        #expect(task.url == url)
        #expect(task.destinationURL == destination)
        #expect((await manager.allTasks()).contains(task))
        
        await manager.cancel(task)
    }
    
    @Test("Task can be cancelled")
    func cancelTask() async {
        let config = DownloadConfiguration(sessionIdentifier: "test.cancel.\(UUID().uuidString)")
        let manager = DownloadManager(configuration: config)
        
        let url = URL(string: "https://example.com/file.zip")!
        let destination = URL(fileURLWithPath: "/tmp/test-file.zip")
        
        let task = await manager.download(url: url, to: destination)
        await manager.cancel(task)
        
        #expect(await task.state == .cancelled)
        #expect((await manager.allTasks()).isEmpty)
    }
    
    @Test("All tasks can be cancelled")
    func cancelAllTasks() async {
        let config = DownloadConfiguration(sessionIdentifier: "test.cancelall.\(UUID().uuidString)")
        let manager = DownloadManager(configuration: config)
        
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
    @Test("Deprecated callback property getter mirrors assigned value")
    @available(*, deprecated)
    func deprecatedCallbackGetterMirrorsAssignedValue() {
        let config = DownloadConfiguration(sessionIdentifier: "test.callback.deprecated.\(UUID().uuidString)")
        let manager = DownloadManager(configuration: config)

        manager.onStateChanged = { _, _ in }
        #expect(manager.onStateChanged != nil)

        manager.onStateChanged = nil
        #expect(manager.onStateChanged == nil)
    }

    @Test("State callback receives waiting and downloading immediately after start")
    func stateCallbackOrdering() async {
        let config = DownloadConfiguration(sessionIdentifier: "test.callback.\(UUID().uuidString)")
        let manager = DownloadManager(configuration: config)
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

    @Test("Persisted tasks can be restored after actor recreation")
    func persistenceRoundTrip() async {
        let sessionIdentifier = "test.persistence.\(UUID().uuidString)"
        let persistenceKey = "com.innonetwork.download.tasks.\(sessionIdentifier)"
        UserDefaults.standard.removeObject(forKey: persistenceKey)
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }

        let taskID = "task-\(UUID().uuidString)"
        let url = URL(string: "https://example.com/file.zip")!
        let destinationURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")

        let writer = DownloadTaskPersistence(sessionIdentifier: sessionIdentifier)
        await writer.upsert(id: taskID, url: url, destinationURL: destinationURL)

        let reader = DownloadTaskPersistence(sessionIdentifier: sessionIdentifier)
        let restored = await reader.record(forID: taskID)

        #expect(restored?.id == taskID)
        #expect(restored?.url == url)
        #expect(restored?.destinationURL == destinationURL)
    }

    @Test("Prune removes stale task records")
    func pruneRemovesStaleRecords() async {
        let sessionIdentifier = "test.persistence.prune.\(UUID().uuidString)"
        let persistenceKey = "com.innonetwork.download.tasks.\(sessionIdentifier)"
        UserDefaults.standard.removeObject(forKey: persistenceKey)
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }

        let keptID = "task-kept"
        let removedID = "task-removed"
        let keptURL = URL(string: "https://example.com/kept.zip")!
        let removedURL = URL(string: "https://example.com/removed.zip")!
        let keptDestination = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-kept.zip")
        let removedDestination = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-removed.zip")

        let persistence = DownloadTaskPersistence(sessionIdentifier: sessionIdentifier)
        await persistence.upsert(id: keptID, url: keptURL, destinationURL: keptDestination)
        await persistence.upsert(id: removedID, url: removedURL, destinationURL: removedDestination)

        await persistence.prune(keeping: [keptID])

        #expect(await persistence.record(forID: keptID) != nil)
        #expect(await persistence.record(forID: removedID) == nil)
    }

    @Test("record(forURL:) returns nil when multiple records share the same URL")
    func recordForURLIsNilWhenAmbiguous() async {
        let sessionIdentifier = "test.persistence.duplicate-url.\(UUID().uuidString)"
        let persistenceKey = "com.innonetwork.download.tasks.\(sessionIdentifier)"
        UserDefaults.standard.removeObject(forKey: persistenceKey)
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }

        let sharedURL = URL(string: "https://example.com/shared.zip")!
        let firstDestination = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-first.zip")
        let secondDestination = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-second.zip")

        let persistence = DownloadTaskPersistence(sessionIdentifier: sessionIdentifier)
        await persistence.upsert(id: "task-1", url: sharedURL, destinationURL: firstDestination)
        await persistence.upsert(id: "task-2", url: sharedURL, destinationURL: secondDestination)

        #expect(await persistence.record(forURL: sharedURL) == nil)
    }
}
