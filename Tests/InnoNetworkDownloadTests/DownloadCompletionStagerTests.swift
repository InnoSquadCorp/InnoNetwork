import Foundation
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkDownload

@Suite("Download completion staging")
struct DownloadCompletionStagerTests {
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
            onCompletion: { _, location, error in
                capturedLocation.withLock { $0 = location }
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

        delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: sourceURL)

        let stagedURL = try #require(capturedLocation.withLock { $0 })
        #expect(capturedError.withLock { $0 } == nil)
        #expect(!fileManager.fileExists(atPath: sourceURL.path))
        #expect(stagedURL.deletingLastPathComponent() == stagingDirectoryURL)
        #expect(try Data(contentsOf: stagedURL) == payload)
    }

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
            onCompletion: { _, location, error in
                capturedLocation.withLock { $0 = location }
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
        let coordinator = DownloadTransferCoordinator(
            session: StubDownloadURLSession(),
            runtimeRegistry: DownloadRuntimeRegistry(),
            persistence: DownloadTaskPersistence(store: InMemoryDownloadTaskStore()),
            eventHub: TaskEventHub(
                policy: configuration.eventDeliveryPolicy,
                metricsReporter: configuration.eventMetricsReporter,
                hubKind: .downloadTask
            )
        )
        let task = DownloadTask(
            url: URL(string: "https://example.invalid/payload.bin")!,
            destinationURL: destinationURL
        )

        await #expect(throws: (any Error).self) {
            try await coordinator.completeDownload(task: task, temporaryLocation: stagedURL)
        }

        #expect(!fileManager.fileExists(atPath: stagedURL.path))
        #expect(await task.state != .completed)
    }
}
