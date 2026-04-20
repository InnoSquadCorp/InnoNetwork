import Foundation
import os
@testable import InnoNetworkDownload


/// Test-only stub conforming to `DownloadURLTask` that records calls and
/// lets the test drive scripted outcomes without touching `URLSession`.
///
/// Mirrors the WebSocket-side `StubWebSocketURLTask` pattern: all state is
/// guarded by `OSAllocatedUnfairLock`, so multiple coordinators can poke
/// the stub from background tasks safely.
final class StubDownloadURLTask: DownloadURLTask, @unchecked Sendable {

    let taskIdentifier: Int
    let originalRequest: URLRequest?

    private struct State {
        var state: URLSessionTask.State = .suspended
        var taskDescription: String?
        var resumeCount = 0
        var suspendCount = 0
        var cancelCount = 0
        var cancelByProducingResumeDataCount = 0
        var cancelByProducingResumeDataResponse: Data?
    }

    private let stateLock: OSAllocatedUnfairLock<State>

    init(
        taskIdentifier: Int = Int.random(in: 1...1_000_000),
        request: URLRequest? = nil,
        initialState: URLSessionTask.State = .suspended
    ) {
        self.taskIdentifier = taskIdentifier
        self.originalRequest = request
        var initial = State()
        initial.state = initialState
        self.stateLock = OSAllocatedUnfairLock(initialState: initial)
    }

    // MARK: Production protocol

    var state: URLSessionTask.State {
        stateLock.withLock { $0.state }
    }

    var taskDescription: String? {
        get { stateLock.withLock { $0.taskDescription } }
        set { stateLock.withLock { $0.taskDescription = newValue } }
    }

    func resume() {
        stateLock.withLock { state in
            state.resumeCount += 1
            state.state = .running
        }
    }

    func suspend() {
        stateLock.withLock { state in
            state.suspendCount += 1
            state.state = .suspended
        }
    }

    func cancel() {
        stateLock.withLock { state in
            state.cancelCount += 1
            state.state = .canceling
        }
    }

    func cancelByProducingResumeData() async -> Data? {
        stateLock.withLock { state in
            state.cancelByProducingResumeDataCount += 1
            state.state = .canceling
            return state.cancelByProducingResumeDataResponse
        }
    }

    // MARK: Test scripting

    /// Pre-seeds the response that the next call to
    /// `cancelByProducingResumeData()` will return.
    func scriptCancelResumeData(_ data: Data?) {
        stateLock.withLock { $0.cancelByProducingResumeDataResponse = data }
    }

    // MARK: Observations

    var resumeCount: Int { stateLock.withLock { $0.resumeCount } }
    var suspendCount: Int { stateLock.withLock { $0.suspendCount } }
    var cancelCount: Int { stateLock.withLock { $0.cancelCount } }
    var cancelByProducingResumeDataCount: Int {
        stateLock.withLock { $0.cancelByProducingResumeDataCount }
    }
}


/// Test-only stub conforming to `DownloadURLSession`. Each
/// `makeDownloadTask(with:)` / `makeDownloadTask(withResumeData:)` call
/// consumes one pre-seeded `StubDownloadURLTask` from `queuedTasks`,
/// falling back to a fresh stub if the queue is empty.
final class StubDownloadURLSession: DownloadURLSession, @unchecked Sendable {

    private struct State {
        var queuedTasks: [StubDownloadURLTask] = []
        var createdTasks: [StubDownloadURLTask] = []
        var lastURL: URL?
        var lastResumeData: Data?
        var didFinishTasksAndInvalidate = false
        var didInvalidateAndCancel = false
    }

    private let stateLock = OSAllocatedUnfairLock<State>(initialState: State())

    init() {}

    /// Enqueue a stub task that will be returned by the next call to
    /// `makeDownloadTask(with:)` or `makeDownloadTask(withResumeData:)`.
    func enqueue(_ task: StubDownloadURLTask) {
        stateLock.withLock { $0.queuedTasks.append(task) }
    }

    func makeDownloadTask(with url: URL) -> any DownloadURLTask {
        stateLock.withLock { state in
            state.lastURL = url
            let next: StubDownloadURLTask
            if !state.queuedTasks.isEmpty {
                next = state.queuedTasks.removeFirst()
            } else {
                next = StubDownloadURLTask(request: URLRequest(url: url))
            }
            state.createdTasks.append(next)
            return next
        }
    }

    func makeDownloadTask(withResumeData data: Data) -> any DownloadURLTask {
        stateLock.withLock { state in
            state.lastResumeData = data
            let next: StubDownloadURLTask
            if !state.queuedTasks.isEmpty {
                next = state.queuedTasks.removeFirst()
            } else {
                next = StubDownloadURLTask(request: nil)
            }
            state.createdTasks.append(next)
            return next
        }
    }

    func allDownloadTasks() async -> [any DownloadURLTask] {
        stateLock.withLock { state in
            state.createdTasks.map { $0 as any DownloadURLTask }
        }
    }

    func finishTasksAndInvalidate() {
        stateLock.withLock { $0.didFinishTasksAndInvalidate = true }
    }

    func invalidateAndCancel() {
        stateLock.withLock { $0.didInvalidateAndCancel = true }
    }

    // MARK: Observations

    var lastURL: URL? { stateLock.withLock { $0.lastURL } }
    var lastResumeData: Data? { stateLock.withLock { $0.lastResumeData } }
    var createdTasks: [StubDownloadURLTask] {
        stateLock.withLock { $0.createdTasks }
    }
    var didFinishTasksAndInvalidate: Bool {
        stateLock.withLock { $0.didFinishTasksAndInvalidate }
    }
    var didInvalidateAndCancel: Bool {
        stateLock.withLock { $0.didInvalidateAndCancel }
    }
}
