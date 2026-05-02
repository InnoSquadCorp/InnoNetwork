import Foundation
import os

@testable import InnoNetworkWebSocket

/// Test-only stub conforming to `WebSocketURLTask` that records calls and lets
/// the test drive scripted outcomes for `receive()` / `sendPing`.
final class StubWebSocketURLTask: WebSocketURLTask, @unchecked Sendable {

    let taskIdentifier: Int

    private struct State {
        var sentMessages: [URLSessionWebSocketTask.Message] = []
        var resumeCount = 0
        var pingCount = 0
        var pendingPong: (@Sendable (Error?) -> Void)?
        var cancelledCloseCode: URLSessionWebSocketTask.CloseCode?
        var cancelledReason: Data?
        var didCancelUnconditionally = false
        var maximumMessageSize: Int = 1 * 1024 * 1024

        var scriptedReceives: [Result<URLSessionWebSocketTask.Message, Error>] = []
        var pendingReceiveContinuations: [UUID: CheckedContinuation<URLSessionWebSocketTask.Message, Error>] = [:]
        var pendingOrder: [UUID] = []
    }

    var maximumMessageSize: Int {
        get { stateLock.withLock { $0.maximumMessageSize } }
        set { stateLock.withLock { $0.maximumMessageSize = newValue } }
    }

    private let stateLock = OSAllocatedUnfairLock<State>(initialState: State())
    private let beforeReceiveCancellationCheckHook =
        OSAllocatedUnfairLock<(@Sendable () async -> Void)?>(initialState: nil)

    init(taskIdentifier: Int = Int.random(in: 1...1_000_000)) {
        self.taskIdentifier = taskIdentifier
    }

    // MARK: Production protocol

    func resume() {
        stateLock.withLock { $0.resumeCount += 1 }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        stateLock.withLock { $0.sentMessages.append(message) }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        let readyResult: Result<URLSessionWebSocketTask.Message, Error>? = stateLock.withLock {
            state -> Result<URLSessionWebSocketTask.Message, Error>? in
            if !state.scriptedReceives.isEmpty {
                return state.scriptedReceives.removeFirst()
            }
            return nil
        }
        if let readyResult {
            let message = try readyResult.get()
            if let hook = beforeReceiveCancellationCheckHook.withLock({ $0 }) {
                await hook()
            }
            try Task.checkCancellation()
            return message
        }

        let continuationID = UUID()
        let stateLock = self.stateLock
        let message = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let alreadyCancelled: Bool = stateLock.withLock { state in
                    if Task.isCancelled { return true }
                    state.pendingReceiveContinuations[continuationID] = continuation
                    state.pendingOrder.append(continuationID)
                    return false
                }
                if alreadyCancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>? = stateLock.withLock { state in
                guard let cont = state.pendingReceiveContinuations.removeValue(forKey: continuationID) else {
                    return nil
                }
                state.pendingOrder.removeAll { $0 == continuationID }
                return cont
            }
            waiter?.resume(throwing: CancellationError())
        }
        if let hook = beforeReceiveCancellationCheckHook.withLock({ $0 }) {
            await hook()
        }
        try Task.checkCancellation()
        return message
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        stateLock.withLock { state in
            state.pingCount += 1
            state.pendingPong = pongReceiveHandler
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        stateLock.withLock { state in
            state.cancelledCloseCode = closeCode
            state.cancelledReason = reason
        }
    }

    func cancel() {
        stateLock.withLock { state in
            state.didCancelUnconditionally = true
        }
    }

    // MARK: Test scripting

    /// Queues a message to be delivered by the next `receive()` call. Already
    /// waiting receivers are resumed immediately.
    func scriptReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        let waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>? = stateLock.withLock { state in
            if let firstID = state.pendingOrder.first {
                state.pendingOrder.removeFirst()
                return state.pendingReceiveContinuations.removeValue(forKey: firstID)
            }
            state.scriptedReceives.append(result)
            return nil
        }
        if let waiter {
            switch result {
            case .success(let message):
                waiter.resume(returning: message)
            case .failure(let error):
                waiter.resume(throwing: error)
            }
        }
    }

    /// Completes the most recently queued ping with an optional error.
    func completePendingPong(with error: Error? = nil) {
        let handler: (@Sendable (Error?) -> Void)? = stateLock.withLock { state in
            let current = state.pendingPong
            state.pendingPong = nil
            return current
        }
        handler?(error)
    }

    func setBeforeReceiveCancellationCheckHook(_ hook: (@Sendable () async -> Void)?) {
        beforeReceiveCancellationCheckHook.withLock { $0 = hook }
    }

    // MARK: Observations

    var sentMessages: [URLSessionWebSocketTask.Message] {
        stateLock.withLock { $0.sentMessages }
    }

    var resumeCount: Int { stateLock.withLock { $0.resumeCount } }
    var pingCount: Int { stateLock.withLock { $0.pingCount } }
    var cancelledCloseCode: URLSessionWebSocketTask.CloseCode? {
        stateLock.withLock { $0.cancelledCloseCode }
    }

    var didCancelUnconditionally: Bool {
        stateLock.withLock { $0.didCancelUnconditionally }
    }

    var hasPendingPong: Bool {
        stateLock.withLock { $0.pendingPong != nil }
    }

    var pendingReceiveCount: Int {
        stateLock.withLock { $0.pendingReceiveContinuations.count }
    }
}


/// Test-only stub conforming to `WebSocketURLSession`. Each `makeWebSocketTask`
/// call consumes one pre-seeded `StubWebSocketURLTask` from `queuedTasks`,
/// falling back to a fresh stub if the queue is empty.
final class StubWebSocketURLSession: WebSocketURLSession, @unchecked Sendable {

    private struct State {
        var queuedTasks: [StubWebSocketURLTask] = []
        var createdTasks: [StubWebSocketURLTask] = []
        var requests: [URLRequest] = []
        var lastRequest: URLRequest?
        var didFinishTasksAndInvalidate = false
        var didInvalidateAndCancel = false
    }

    private let stateLock = OSAllocatedUnfairLock<State>(initialState: State())

    init() {}

    /// Enqueue a stub task that will be returned by the next call to
    /// `makeWebSocketTask(with:)`.
    func enqueue(_ task: StubWebSocketURLTask) {
        stateLock.withLock { $0.queuedTasks.append(task) }
    }

    func makeWebSocketTask(with request: URLRequest) -> any WebSocketURLTask {
        stateLock.withLock { state in
            state.lastRequest = request
            state.requests.append(request)
            let next: StubWebSocketURLTask
            if !state.queuedTasks.isEmpty {
                next = state.queuedTasks.removeFirst()
            } else {
                next = StubWebSocketURLTask()
            }
            state.createdTasks.append(next)
            return next
        }
    }

    func finishTasksAndInvalidate() {
        stateLock.withLock { $0.didFinishTasksAndInvalidate = true }
    }

    func invalidateAndCancel() {
        stateLock.withLock { $0.didInvalidateAndCancel = true }
    }

    // MARK: Observations

    var lastRequest: URLRequest? { stateLock.withLock { $0.lastRequest } }
    var requests: [URLRequest] { stateLock.withLock { $0.requests } }
    var createdTasks: [StubWebSocketURLTask] { stateLock.withLock { $0.createdTasks } }
}
