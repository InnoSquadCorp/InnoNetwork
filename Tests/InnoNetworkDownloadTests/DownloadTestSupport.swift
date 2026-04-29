import Foundation

@testable import InnoNetworkDownload

/// Deterministic `NetworkMonitoring` double for retry tests.
///
/// `currentSnapshot` controls what `currentSnapshot()` returns; use
/// `setNextChangeSnapshot(_:)` to control what `waitForChange(from:timeout:)`
/// returns, and `changeDelay` to control how long that change is delayed.
actor MockNetworkMonitor: NetworkMonitoring {
    private var _currentSnapshot: NetworkSnapshot?
    private var _nextChangeSnapshot: NetworkSnapshot?
    private var _changeDelay: TimeInterval = 0
    private(set) var waitForChangeCallCount = 0

    init(
        currentSnapshot: NetworkSnapshot? = NetworkSnapshot(status: .satisfied, interfaceTypes: [.wifi]),
        nextChangeSnapshot: NetworkSnapshot? = nil,
        changeDelay: TimeInterval = 0
    ) {
        self._currentSnapshot = currentSnapshot
        self._nextChangeSnapshot = nextChangeSnapshot
        self._changeDelay = changeDelay
    }

    func setCurrentSnapshot(_ snapshot: NetworkSnapshot?) {
        _currentSnapshot = snapshot
    }

    func setNextChangeSnapshot(_ snapshot: NetworkSnapshot?) {
        _nextChangeSnapshot = snapshot
    }

    func currentSnapshot() async -> NetworkSnapshot? {
        _currentSnapshot
    }

    func waitForChange(from snapshot: NetworkSnapshot?, timeout: TimeInterval?) async -> NetworkSnapshot? {
        waitForChangeCallCount += 1
        if _changeDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(_changeDelay * 1_000_000_000))
        }
        return _nextChangeSnapshot
    }
}


/// Waits for the manager runtime to assign a task identifier, optionally excluding a prior one.
func waitForRuntimeTaskIdentifier(
    manager: DownloadManager,
    task: DownloadTask,
    excluding previousIdentifier: Int? = nil,
    timeout: TimeInterval = 2.0
) async -> Int? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let identifier = await manager.runtimeTaskIdentifier(for: task) {
            // Stub download task identifiers are monotonic, so a different
            // identifier means the retry path really did register a fresh
            // runtime task.
            if previousIdentifier == nil || identifier != previousIdentifier {
                return identifier
            }
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return nil
}


/// Waits for `task.state` to satisfy `predicate`.
func waitForTaskState(
    _ task: DownloadTask,
    timeout: TimeInterval = 2.0,
    predicate: @escaping @Sendable (DownloadState) -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate(await task.state) {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}


/// Cancels the live runtime URLSession task, then injects a synthetic completion.
func injectSyntheticCompletion(
    manager: DownloadManager,
    task: DownloadTask,
    taskIdentifier: Int,
    location: URL?,
    error: SendableUnderlyingError?
) async {
    await manager.cancelRuntimeURLTask(for: task)
    await manager.handleCompletion(
        taskIdentifier: taskIdentifier,
        location: location,
        error: error
    )
}


/// Produces a unique sessionIdentifier for a download test.
func makeDownloadTestSessionIdentifier(_ label: String) -> String {
    "test.download.\(label).\(UUID().uuidString)"
}
