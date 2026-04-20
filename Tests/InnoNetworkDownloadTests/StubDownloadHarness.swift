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
/// - `injectCompletion(...)` simulates the URLSession delegate's completion
///   callback and also cancels the live stub runtime task, mirroring the
///   prior `injectSyntheticCompletion` behavior.
final class StubDownloadHarness: Sendable {
    let manager: DownloadManager
    let stubSession: StubDownloadURLSession
    let stubTask: StubDownloadURLTask
    let stubTaskIdentifier: Int

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
        label: String = "stub"
    ) throws {
        let identifier = "test.download.\(label).\(UUID().uuidString)"
        self.sessionIdentifier = identifier

        let stubSession = StubDownloadURLSession()
        let stubTask = StubDownloadURLTask()
        stubSession.enqueue(stubTask)
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
            store: InMemoryDownloadTaskStore()
        )
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


/// Minimal in-memory `DownloadTaskStore` so the stub harness does not touch
/// disk via `AppendLogDownloadTaskStore`. Mirrors the testonly store in
/// `DownloadRetryTimingTests` but lives in the shared harness file.
private actor InMemoryDownloadTaskStore: DownloadTaskStore {
    private var records: [String: DownloadTaskPersistence.Record] = [:]

    func upsert(id: String, url: URL, destinationURL: URL) async {
        records[id] = DownloadTaskPersistence.Record(
            id: id,
            url: url,
            destinationURL: destinationURL
        )
    }

    func remove(id: String) async {
        records.removeValue(forKey: id)
    }

    func record(forID id: String) async -> DownloadTaskPersistence.Record? {
        records[id]
    }

    func allRecords() async -> [DownloadTaskPersistence.Record] {
        Array(records.values)
    }

    func id(forURL url: URL?) async -> String? {
        guard let url else { return nil }
        return records.values.first(where: { $0.url == url })?.id
    }

    func prune(keeping ids: Set<String>) async {
        records = records.filter { ids.contains($0.key) }
    }
}
