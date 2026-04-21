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

    private let callbacks: DownloadSessionDelegateCallbacks
    private let backgroundCompletionStore: BackgroundCompletionStore
    private let sessionIdentifier: String

    init(
        maxRetryCount: Int = 2,
        maxTotalRetries: Int? = nil,
        retryDelay: TimeInterval = 0,
        networkMonitor: (any NetworkMonitoring)? = nil,
        waitsForNetworkChanges: Bool = false,
        networkChangeTimeout: TimeInterval? = 0.5,
        label: String = "stub",
        prepopulatedRecords: [DownloadTaskPersistence.Record] = [],
        prequeuedStubs: [StubDownloadURLTask] = [],
        preinstalledStubs: [StubDownloadURLTask] = []
    ) throws {
        let identifier = "test.download.\(label).\(UUID().uuidString)"
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

        let persistence = DownloadTaskPersistence(
            store: InMemoryDownloadTaskStore(seed: prepopulatedRecords)
        )
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
    func startDownload(url: URL = URL(string: "https://example.invalid/file.zip")!) async -> DownloadTask {
        await manager.download(
            url: url,
            to: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        )
    }

    /// Injects a synthetic completion for the given task identifier. Matches
    /// the old `injectSyntheticCompletion` helper but drives it through the
    /// package-level callbacks so both success (`location`) and failure
    /// (`error`) paths flow through the same delegate wiring.
    func injectCompletion(
        taskIdentifier: Int,
        location: URL? = nil,
        error: SendableUnderlyingError? = nil
    ) {
        manager.handleCompletion(
            taskIdentifier: taskIdentifier,
            location: location,
            error: error
        )
    }
}
