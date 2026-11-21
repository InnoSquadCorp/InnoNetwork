import Foundation
import os

/// Lifecycle events emitted by a ``NetworkOperation``.
///
/// Events are payload-free so they can be compared, stored, and logged. The
/// full ``NetworkError`` of a failed operation is thrown by
/// ``NetworkOperation/value()``.
public enum NetworkOperationEvent: Sendable, Equatable {
    /// The operation began executing. Always the first event.
    case started(id: UUID)
    /// The operation produced its value. Always the last event.
    case succeeded(id: UUID)
    /// The operation failed, was cancelled, or exceeded its deadline. Always
    /// the last event. `summary` is the contextual summary that
    /// ``NetworkOperation/failureSummary()`` also returns.
    case failed(id: UUID, summary: NetworkErrorSummary)
}

/// A cancellation-capable handle returned before network execution completes.
///
/// Create one with `start(_:replaySafety:deadline:)` on any
/// ``NetworkClient`` or ``EncodedRequestClient``, or with
/// `startUpload(_:replaySafety:deadline:)` on an ``UploadNetworkClient``.
///
/// The operation records its bounded start/terminal lifecycle, and every
/// access to ``events`` replays it, so any number of consumers, early or late,
/// each observe the whole lifecycle. Await ``value()`` for the typed response
/// or call ``cancel()``; the caller need not keep the client, which the
/// running operation holds until it finishes.
/// Cancelling a task that is currently awaiting ``value()`` also cancels this
/// operation so structured callers do not leave detached network work behind.
public struct NetworkOperation<Value: Sendable>: Sendable {
    /// Identifier shared by every event of this operation.
    public let id: UUID

    /// The bounded lifecycle stream: ``NetworkOperationEvent/started(id:)``
    /// followed by one terminal event.
    ///
    /// Each access returns a new stream that first replays the events the
    /// operation has already emitted and then delivers the rest, so a
    /// consumer that subscribes late still receives both, and several
    /// consumers do not divide the events between them. A stream obtained
    /// after the operation finished delivers both events and ends.
    public var events: AsyncStream<NetworkOperationEvent> {
        eventLog.subscribe()
    }

    private let eventLog: NetworkOperationEventLog
    private let task: Task<Result<Value, NetworkOperationFailure>, Never>

    package init(
        id: UUID,
        eventLog: NetworkOperationEventLog,
        task: Task<Result<Value, NetworkOperationFailure>, Never>
    ) {
        self.id = id
        self.eventLog = eventLog
        self.task = task
    }

    /// Awaits the typed response, or throws the same ``NetworkError`` that
    /// `request(_:)` would have thrown.
    ///
    /// An expired ``NetworkOperationDeadline`` throws
    /// ``NetworkError/timeout(reason:underlying:)`` with
    /// ``TimeoutReason/operationDeadline(_:)``.
    public func value() async throws(NetworkError) -> Value {
        try await value(onWait: {})
    }

    /// Internal observation seam: invoked only after cancellation forwarding
    /// has been installed. Tests can distinguish pre-entry and active waits.
    package func value(onWait: @Sendable () -> Void) async throws(NetworkError) -> Value {
        let result = await withTaskCancellationHandler {
            onWait()
            return await task.value
        } onCancel: {
            task.cancel()
        }
        switch result {
        case .success(let value):
            return value
        case .failure(let failure):
            throw failure.error
        }
    }

    /// Awaits completion and returns the payload-free summary of the failure,
    /// or `nil` when the operation succeeded.
    ///
    /// Unlike ``NetworkError/summary``, this summary knows the request's
    /// method, authentication, and replay safety, so its
    /// ``NetworkErrorSummary/recovery`` can recommend a retry, a wait for
    /// connectivity, or reauthentication. It is the same value the
    /// ``events`` stream delivers in
    /// ``NetworkOperationEvent/failed(id:summary:)``.
    ///
    /// ```swift
    /// do {
    ///     let user = try await operation.value()
    /// } catch {
    ///     if await operation.failureSummary()?.recovery == .reauthenticate {
    ///         await session.signOut()
    ///     }
    /// }
    /// ```
    public func failureSummary() async -> NetworkErrorSummary? {
        switch await task.value {
        case .success:
            return nil
        case .failure(let failure):
            return failure.summary
        }
    }

    /// Cancels the operation. A pending ``value()`` then throws
    /// ``NetworkError/cancelled``. The running operation holds the client
    /// until it finishes, so cancelling works after the caller released its
    /// own reference.
    public func cancel() {
        task.cancel()
    }

    /// Whether ``cancel()`` was called or a task awaiting ``value()`` was
    /// cancelled.
    public var isCancelled: Bool {
        task.isCancelled
    }
}

/// The terminal failure of an operation: the error thrown to the caller and
/// its contextual summary, computed once when the operation ends.
package struct NetworkOperationFailure: Error, Sendable {
    package let error: NetworkError
    package let summary: NetworkErrorSummary
}

/// The lifecycle an operation has emitted so far, delivered to every
/// subscriber.
///
/// An `AsyncStream` hands each element to only one of the tasks iterating
/// it, so a single shared stream would divide the events among consumers.
/// The log instead gives each subscriber its own stream, replays the
/// recorded events into it, and then delivers the remaining ones. An
/// operation emits at most two events, so the log keeps all of them.
package final class NetworkOperationEventLog: Sendable {
    private typealias Continuation = AsyncStream<NetworkOperationEvent>.Continuation

    private struct State {
        var events: [NetworkOperationEvent] = []
        var isFinished = false
        var subscribers: [UInt64: Continuation] = [:]
        var nextSubscriberID: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package init() {}

    /// Records `event` and delivers it to every current subscriber.
    ///
    /// Delivery happens under the lock that also serializes replay, so each
    /// subscriber receives the events in the order they were recorded.
    package func record(_ event: NetworkOperationEvent) {
        state.withLock { state in
            guard !state.isFinished else { return }
            state.events.append(event)
            for continuation in state.subscribers.values {
                continuation.yield(event)
            }
        }
    }

    /// Records the terminal `event`, delivers it, and ends every stream.
    package func finish(with event: NetworkOperationEvent) {
        let subscribers = state.withLock { state -> [Continuation] in
            guard !state.isFinished else { return [] }
            state.events.append(event)
            state.isFinished = true
            let subscribers = Array(state.subscribers.values)
            state.subscribers.removeAll()
            for continuation in subscribers {
                continuation.yield(event)
            }
            return subscribers
        }
        // Ending a stream runs its termination handler, which takes the lock.
        for continuation in subscribers {
            continuation.finish()
        }
    }

    /// A new stream that replays the recorded events, then delivers the rest
    /// and ends with the operation.
    package func subscribe() -> AsyncStream<NetworkOperationEvent> {
        let (stream, continuation) = AsyncStream<NetworkOperationEvent>.makeStream()
        let isFinished = state.withLock { state -> Bool in
            for event in state.events {
                continuation.yield(event)
            }
            guard !state.isFinished else { return true }
            let id = state.nextSubscriberID
            state.nextSubscriberID &+= 1
            state.subscribers[id] = continuation
            // Runs when the consumer stops early; never while the lock is
            // held, because the log ends streams only after releasing it.
            continuation.onTermination = { [weak self] _ in
                self?.unsubscribe(id)
            }
            return false
        }
        if isFinished {
            continuation.finish()
        }
        return stream
    }

    private func unsubscribe(_ id: UInt64) {
        // Released after the lock: dropping the last reference to a stream
        // can run its termination handler.
        let removed = state.withLock { $0.subscribers.removeValue(forKey: id) }
        _ = removed
    }
}
