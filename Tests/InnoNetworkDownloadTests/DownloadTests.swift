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
        #expect(config.retryDelay == 1.0)
        #expect(config.allowsCellularAccess == true)
    }
    
    @Test("Custom configuration is applied correctly")
    func customConfiguration() {
        let config = DownloadConfiguration(
            maxConcurrentDownloads: 5,
            maxRetryCount: 5,
            retryDelay: 2.0,
            allowsCellularAccess: false
        )
        
        #expect(config.maxConcurrentDownloads == 5)
        #expect(config.maxRetryCount == 5)
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
        
        await task.reset()
        
        #expect(await task.state == .idle)
        #expect(await task.retryCount == 0)
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
