import Foundation
import os

@testable import InnoNetworkWebSocket

/// Test-only stub conforming to `WebSocketURLTask` that records calls and lets
/// the test drive scripted outcomes for `receive()` / `sendPing`.
final class StubWebSocketURLTask: WebSocketURLTask, @unchecked Sendable {

    private struct PendingReceiveWaiter {
        let id: UUID
        let expectedCount: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    enum ReceiveCancellationBehavior: Sendable, Equatable {
        /// Models an async operation that directly observes Swift Task
        /// cancellation, which is convenient for most focused unit tests.
        case cooperative
        /// Models Foundation's transport boundary: cancelling the surrounding
        /// Swift Task alone does not complete `receive()`; only cancelling the
        /// underlying URL task releases the pending operation.
        case transportCancellationOnly
    }

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
        var pendingReceiveWaiters: [PendingReceiveWaiter] = []

        mutating func removeSatisfiedPendingReceiveWaiters() -> [CheckedContinuation<Bool, Never>] {
            var ready: [CheckedContinuation<Bool, Never>] = []
            var remaining: [PendingReceiveWaiter] = []
            for waiter in pendingReceiveWaiters {
                if pendingReceiveContinuations.count == waiter.expectedCount {
                    ready.append(waiter.continuation)
                } else {
                    remaining.append(waiter)
                }
            }
            pendingReceiveWaiters = remaining
            return ready
        }
    }

    var maximumMessageSize: Int {
        get { stateLock.withLock { $0.maximumMessageSize } }
        set { stateLock.withLock { $0.maximumMessageSize = newValue } }
    }

    private let stateLock = OSAllocatedUnfairLock<State>(initialState: State())
    private let beforeReceiveCancellationCheckHook =
        OSAllocatedUnfairLock<(@Sendable () async -> Void)?>(initialState: nil)
    private let beforeSendCompletionHook =
        OSAllocatedUnfairLock<(@Sendable () async -> Void)?>(initialState: nil)
    private let receiveCancellationBehavior: ReceiveCancellationBehavior

    init(
        taskIdentifier: Int = Int.random(in: 1...1_000_000),
        receiveCancellationBehavior: ReceiveCancellationBehavior = .cooperative
    ) {
        self.taskIdentifier = taskIdentifier
        self.receiveCancellationBehavior = receiveCancellationBehavior
    }

    // MARK: Production protocol

    func resume() {
        stateLock.withLock { $0.resumeCount += 1 }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        stateLock.withLock { $0.sentMessages.append(message) }
        if let hook = beforeSendCompletionHook.withLock({ $0 }) {
            await hook()
        }
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
            if receiveCancellationBehavior == .cooperative {
                try Task.checkCancellation()
            }
            return message
        }

        let continuationID = UUID()
        let message: URLSessionWebSocketTask.Message
        switch receiveCancellationBehavior {
        case .cooperative:
            let stateLock = self.stateLock
            message = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let registration: (Bool, [CheckedContinuation<Bool, Never>]) =
                        stateLock.withLock { state in
                            if Task.isCancelled { return (true, []) }
                            state.pendingReceiveContinuations[continuationID] = continuation
                            state.pendingOrder.append(continuationID)
                            return (false, state.removeSatisfiedPendingReceiveWaiters())
                        }
                    resumePendingReceiveWaiters(registration.1)
                    if registration.0 {
                        continuation.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                let removal:
                    (
                        CheckedContinuation<URLSessionWebSocketTask.Message, Error>?,
                        [CheckedContinuation<Bool, Never>]
                    ) = stateLock.withLock { state in
                        guard let cont = state.pendingReceiveContinuations.removeValue(forKey: continuationID) else {
                            return (nil, [])
                        }
                        state.pendingOrder.removeAll { $0 == continuationID }
                        return (cont, state.removeSatisfiedPendingReceiveWaiters())
                    }
                removal.0?.resume(throwing: CancellationError())
                resumePendingReceiveWaiters(removal.1)
            }
        case .transportCancellationOnly:
            message = try await withCheckedThrowingContinuation { continuation in
                let registration: (Bool, [CheckedContinuation<Bool, Never>]) = stateLock.withLock { state in
                    if state.didCancelUnconditionally { return (true, []) }
                    state.pendingReceiveContinuations[continuationID] = continuation
                    state.pendingOrder.append(continuationID)
                    return (false, state.removeSatisfiedPendingReceiveWaiters())
                }
                resumePendingReceiveWaiters(registration.1)
                if registration.0 {
                    continuation.resume(throwing: URLError(.cancelled))
                }
            }
        }
        if let hook = beforeReceiveCancellationCheckHook.withLock({ $0 }) {
            await hook()
        }
        if receiveCancellationBehavior == .cooperative {
            try Task.checkCancellation()
        }
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
        let cancellation:
            (
                [CheckedContinuation<URLSessionWebSocketTask.Message, Error>],
                [CheckedContinuation<Bool, Never>]
            ) = stateLock.withLock { state in
                state.didCancelUnconditionally = true
                let waiters = Array(state.pendingReceiveContinuations.values)
                state.pendingReceiveContinuations.removeAll(keepingCapacity: false)
                state.pendingOrder.removeAll(keepingCapacity: false)
                return (waiters, state.removeSatisfiedPendingReceiveWaiters())
            }
        for waiter in cancellation.0 {
            waiter.resume(throwing: URLError(.cancelled))
        }
        resumePendingReceiveWaiters(cancellation.1)
    }

    // MARK: Test scripting

    /// Queues a message to be delivered by the next `receive()` call. Already
    /// waiting receivers are resumed immediately.
    func scriptReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        let delivery:
            (
                CheckedContinuation<URLSessionWebSocketTask.Message, Error>?,
                [CheckedContinuation<Bool, Never>]
            ) = stateLock.withLock { state in
                if let firstID = state.pendingOrder.first {
                    state.pendingOrder.removeFirst()
                    let waiter = state.pendingReceiveContinuations.removeValue(forKey: firstID)
                    return (waiter, state.removeSatisfiedPendingReceiveWaiters())
                }
                state.scriptedReceives.append(result)
                return (nil, [])
            }
        if let waiter = delivery.0 {
            switch result {
            case .success(let message):
                waiter.resume(returning: message)
            case .failure(let error):
                waiter.resume(throwing: error)
            }
        }
        resumePendingReceiveWaiters(delivery.1)
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

    func setBeforeSendCompletionHook(_ hook: (@Sendable () async -> Void)?) {
        beforeSendCompletionHook.withLock { $0 = hook }
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

    func waitForPendingReceiveCount(_ expectedCount: Int, timeout: TimeInterval = 5.0) async -> Bool {
        if stateLock.withLock({ $0.pendingReceiveContinuations.count == expectedCount }) {
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldWait = stateLock.withLock { state in
                    guard state.pendingReceiveContinuations.count != expectedCount else { return false }
                    state.pendingReceiveWaiters.append(
                        PendingReceiveWaiter(
                            id: id,
                            expectedCount: expectedCount,
                            continuation: continuation
                        )
                    )
                    return true
                }
                guard shouldWait else {
                    continuation.resume(returning: true)
                    return
                }
                schedulePendingReceiveTimeout(id: id, timeout: timeout)
            }
        } onCancel: {
            finishPendingReceiveWaiter(id: id, result: false)
        }
    }

    private func schedulePendingReceiveTimeout(id: UUID, timeout: TimeInterval) {
        Task { [self] in
            try? await ContinuousClock().sleep(for: .seconds(max(timeout, 0)))
            finishPendingReceiveWaiter(id: id, result: false)
        }
    }

    private func finishPendingReceiveWaiter(id: UUID, result: Bool) {
        let continuation: CheckedContinuation<Bool, Never>? = stateLock.withLock { state in
            guard let index = state.pendingReceiveWaiters.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return state.pendingReceiveWaiters.remove(at: index).continuation
        }
        continuation?.resume(returning: result)
    }

    private func resumePendingReceiveWaiters(_ waiters: [CheckedContinuation<Bool, Never>]) {
        for waiter in waiters {
            waiter.resume(returning: true)
        }
    }
}


/// Test-only stub conforming to `WebSocketURLSession`. Each `makeWebSocketTask`
/// call consumes one pre-seeded `StubWebSocketURLTask` from `queuedTasks`,
/// falling back to a fresh stub if the queue is empty.
final class StubWebSocketURLSession: WebSocketURLSession, @unchecked Sendable {

    private struct InvalidationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var queuedTasks: [StubWebSocketURLTask] = []
        var createdTasks: [StubWebSocketURLTask] = []
        var requests: [URLRequest] = []
        var lastRequest: URLRequest?
        var didFinishTasksAndInvalidate = false
        var didInvalidateAndCancel = false
        var invalidationWaiters: [InvalidationWaiter] = []
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
        let waiters: [CheckedContinuation<Bool, Never>] = stateLock.withLock { state in
            state.didInvalidateAndCancel = true
            let waiters = state.invalidationWaiters.map(\.continuation)
            state.invalidationWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: true)
        }
    }

    // MARK: Observations

    var lastRequest: URLRequest? { stateLock.withLock { $0.lastRequest } }
    var requests: [URLRequest] { stateLock.withLock { $0.requests } }
    var createdTasks: [StubWebSocketURLTask] { stateLock.withLock { $0.createdTasks } }
    var didFinishTasksAndInvalidate: Bool { stateLock.withLock { $0.didFinishTasksAndInvalidate } }
    var didInvalidateAndCancel: Bool { stateLock.withLock { $0.didInvalidateAndCancel } }

    func waitForInvalidation(timeout: TimeInterval = 5.0) async -> Bool {
        if stateLock.withLock({ $0.didInvalidateAndCancel }) {
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldWait = stateLock.withLock { state in
                    guard !state.didInvalidateAndCancel else { return false }
                    state.invalidationWaiters.append(
                        InvalidationWaiter(id: id, continuation: continuation)
                    )
                    return true
                }
                guard shouldWait else {
                    continuation.resume(returning: true)
                    return
                }
                scheduleInvalidationTimeout(id: id, timeout: timeout)
            }
        } onCancel: {
            finishInvalidationWaiter(id: id, result: false)
        }
    }

    private func scheduleInvalidationTimeout(id: UUID, timeout: TimeInterval) {
        Task { [self] in
            try? await ContinuousClock().sleep(for: .seconds(max(timeout, 0)))
            finishInvalidationWaiter(id: id, result: false)
        }
    }

    private func finishInvalidationWaiter(id: UUID, result: Bool) {
        let continuation: CheckedContinuation<Bool, Never>? = stateLock.withLock { state in
            guard let index = state.invalidationWaiters.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return state.invalidationWaiters.remove(at: index).continuation
        }
        continuation?.resume(returning: result)
    }
}
