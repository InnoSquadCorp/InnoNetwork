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
            onCompletion: { taskIdentifier, location, _ in
                #expect(taskIdentifier == 42)
                capturedLocation.withLock { $0 = location }
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
            .completion(taskIdentifier: 7, location: stagedURL, error: nil),
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
}


private func enqueueCompletionWithoutInstallingHandler(location: URL) {
    let callbacks = DownloadSessionDelegateCallbacks()
    callbacks.handleCompletion(taskIdentifier: 1, location: location, error: nil)
}
