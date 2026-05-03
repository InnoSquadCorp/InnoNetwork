import Foundation
import os

@testable import InnoNetwork
@testable import InnoNetworkDownload

/// Wires a `DownloadManager` against a stub `URLSession` and an in-memory
/// persistence store so retry / pause-resume / restore tests can drive
/// completions deterministically (no `.invalid` URL + real URLSession race).
///
/// - `stubSession` / `stubTask` expose the first task returned by
///   `makeDownloadTask(with:)`. Tests that expect multiple retries pre-queue
///   additional stubs via `stubSession.enqueue(_:)`.
/// - `persistence` is exposed so restore-path tests can inspect records
///   after the restore coordinator runs; pre-seeded records are supplied
///   via `prepopulatedRecords:` on init.
/// - `injectCompletion(...)` simulates the URLSession delegate's completion
///   callback and also cancels the live stub runtime task, mirroring the
///   prior `injectSyntheticCompletion` behavior.
final class StubDownloadHarness: Sendable {
    let manager: DownloadManager
    let stubSession: StubDownloadURLSession
    let stubTask: StubDownloadURLTask
    let stubTaskIdentifier: Int
    let persistence: DownloadTaskPersistence
    let store: InMemoryDownloadTaskStore

    private let callbacks: DownloadSessionDelegateCallbacks
    private let backgroundCompletionStore: BackgroundCompletionStore
    let sessionIdentifier: String

    init(
        maxRetryCount: Int = 2,
        maxTotalRetries: Int? = nil,
        retryDelay: TimeInterval = 0,
        networkMonitor: (any NetworkMonitoring)? = nil,
        waitsForNetworkChanges: Bool = false,
        networkChangeTimeout: TimeInterval? = 0.5,
        label: String = "stub",
        sessionIdentifier: String? = nil,
        prepopulatedRecords: [DownloadTaskPersistence.Record] = [],
        prequeuedStubs: [StubDownloadURLTask] = [],
        preinstalledStubs: [StubDownloadURLTask] = []
    ) throws {
        let identifier = sessionIdentifier ?? "test.download.\(label).\(UUID().uuidString)"
        self.sessionIdentifier = identifier

        let stubSession = StubDownloadURLSession()
        // Preinstall must happen *before* the manager's restore task runs
        // (which happens on init). Do it before manager construction.
        for stub in preinstalledStubs {
            stubSession.preinstall(stub)
        }
        // Default stub is enqueued first so it is consumed by the initial
        // `makeDownloadTask(with:)` call. Prequeued stubs are served in
        // order for subsequent calls (retry / resume).
        let stubTask = StubDownloadURLTask()
        stubSession.enqueue(stubTask)
        for stub in prequeuedStubs {
            stubSession.enqueue(stub)
        }
        self.stubSession = stubSession
        self.stubTask = stubTask
        self.stubTaskIdentifier = stubTask.taskIdentifier

        let callbacks = DownloadSessionDelegateCallbacks()
        let backgroundCompletionStore = BackgroundCompletionStore()
        let delegate = DownloadSessionDelegate(
            callbacks: callbacks,
            backgroundCompletionStore: backgroundCompletionStore
        )
        self.callbacks = callbacks
        self.backgroundCompletionStore = backgroundCompletionStore
        stubSession.setInvalidationHandler {
            callbacks.handleInvalidation(nil)
        }

        let store = InMemoryDownloadTaskStore(seed: prepopulatedRecords)
        self.store = store
        let persistence = DownloadTaskPersistence(store: store)
        self.persistence = persistence
        let config = DownloadConfiguration(
            maxRetryCount: maxRetryCount,
            maxTotalRetries: maxTotalRetries ?? (maxRetryCount + 3),
            retryDelay: retryDelay,
            sessionIdentifier: identifier,
            networkMonitor: networkMonitor,
            waitsForNetworkChanges: waitsForNetworkChanges,
            networkChangeTimeout: networkChangeTimeout
        )

        self.manager = try DownloadManager(
            configuration: config,
            persistence: persistence,
            urlSession: stubSession,
            delegate: delegate,
            callbacks: callbacks,
            backgroundCompletionStore: backgroundCompletionStore
        )
    }

    /// Starts a new download and returns the created `DownloadTask`. Callers
    /// can then await `waitForRuntimeTaskIdentifier` to sync with the stub's
    /// registered taskIdentifier.
    func startDownload(
        url: URL = URL(string: "https://example.invalid/file.zip")!,
        destinationURL: URL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
    ) async -> DownloadTask {
        await manager.download(
            url: url,
            to: destinationURL
        )
    }

    /// Injects a synthetic completion directly into the actor for tests that
    /// need to await the terminal handling before asserting.
    func injectCompletion(
        taskIdentifier: Int,
        location: URL? = nil,
        error: SendableUnderlyingError? = nil
    ) async {
        await manager.handleCompletion(
            taskIdentifier: taskIdentifier,
            location: location,
            error: error
        )
    }

    func injectDelegateProgress(
        taskIdentifier: Int,
        bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        callbacks.handleProgress(
            taskIdentifier: taskIdentifier,
            bytesWritten: bytesWritten,
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        )
    }

    func injectDelegateCompletion(
        taskIdentifier: Int,
        location: URL? = nil,
        error: SendableUnderlyingError? = nil
    ) {
        callbacks.handleCompletion(
            taskIdentifier: taskIdentifier,
            location: location,
            error: error
        )
    }

    func markBackgroundEventsFinished() async {
        _ = await backgroundCompletionStore.take()
    }

    func handleBackgroundSessionCompletion(_ completion: @escaping @Sendable () -> Void) {
        manager.handleBackgroundSessionCompletion(sessionIdentifier, completion: completion)
    }
}
