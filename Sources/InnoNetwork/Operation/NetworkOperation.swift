import Foundation

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
/// The event stream is registered before work starts and retains the bounded
/// start/terminal lifecycle for a late first consumer. Await ``value()`` for
/// the typed response or call ``cancel()`` without retaining the client.
/// Cancelling a task that is currently awaiting ``value()`` also cancels this
/// operation so structured callers do not leave detached network work behind.
public struct NetworkOperation<Value: Sendable>: Sendable {
    /// Identifier shared by every event of this operation.
    public let id: UUID
    /// The bounded lifecycle stream: ``NetworkOperationEvent/started(id:)``
    /// followed by one terminal event. It is registered before work starts,
    /// so a consumer that subscribes late still receives both.
    public let events: AsyncStream<NetworkOperationEvent>

    private let task: Task<Result<Value, NetworkOperationFailure>, Never>

    package init(
        id: UUID,
        events: AsyncStream<NetworkOperationEvent>,
        task: Task<Result<Value, NetworkOperationFailure>, Never>
    ) {
        self.id = id
        self.events = events
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
    /// ``NetworkError/cancelled``. The handle does not retain the client, so
    /// cancelling works after the client has gone away.
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
