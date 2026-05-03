import Foundation
import InnoNetworkWebSocket
import os

/// Collects `WebSocketEvent` values published through `TaskEventHub` for
/// assertion in multi-cycle timing / reconnect / receive / messaging tests.
///
/// Consumers can depend on this type from their own test targets by adding
/// the `InnoNetworkTestSupport` product. The type is intentionally
/// observation-only — callers append events from their listener closure
/// and then read derived counts/snapshots; nothing in this type drives
/// the underlying WebSocket or rewinds time.
///
/// Thread safety: `OSAllocatedUnfairLock` guards the internal event buffer,
/// so the recorder is safe to call from event-hub listener closures (which
/// run on arbitrary background tasks).
public final class WebSocketEventRecorder: Sendable {
    private struct EventWaiter {
        let id: UUID
        let predicate: @Sendable (WebSocketEvent) -> Bool
        let continuation: CheckedContinuation<Bool, Error>
    }

    private struct State {
        var events: [WebSocketEvent] = []
        var waiters: [EventWaiter] = []

        mutating func removeSatisfiedWaiters() -> [CheckedContinuation<Bool, Error>] {
            var ready: [CheckedContinuation<Bool, Error>] = []
            var remaining: [EventWaiter] = []
            for waiter in waiters {
                if events.contains(where: waiter.predicate) {
                    ready.append(waiter.continuation)
                } else {
                    remaining.append(waiter)
                }
            }
            waiters = remaining
            return ready
        }
    }

    private let stateLock = OSAllocatedUnfairLock<State>(initialState: State())

    public init() {}

    public func record(_ event: WebSocketEvent) {
        let ready = stateLock.withLock { state in
            state.events.append(event)
            return state.removeSatisfiedWaiters()
        }
        for continuation in ready {
            continuation.resume(returning: true)
        }
    }

    public func snapshot() -> [WebSocketEvent] {
        stateLock.withLock { $0.events }
    }

    public var pongCount: Int {
        stateLock.withLock { state in
            let list = state.events
            return list.reduce(0) { acc, event in
                if case .pong = event { return acc + 1 }
                return acc
            }
        }
    }

    /// All observed `.ping` contexts in order.
    public var pingContexts: [WebSocketPingContext] {
        stateLock.withLock { state in
            let list = state.events
            return list.compactMap { event in
                if case .ping(let context) = event { return context }
                return nil
            }
        }
    }

    /// All observed `.pong` contexts in order. Tests pair this with
    /// ``pingContexts`` or with a harness-captured `setOnPongHandler`
    /// snapshot to assert that the event-stream and callback paths
    /// deliver identical `WebSocketPongContext` values.
    public var pongContexts: [WebSocketPongContext] {
        stateLock.withLock { state in
            let list = state.events
            return list.compactMap { event in
                if case .pong(let context) = event { return context }
                return nil
            }
        }
    }

    /// Count of `.ping` events observed since the recorder started listening.
    /// Paired with `pongCount` so tests can assert the `.ping → .pong` cadence
    /// emitted by the heartbeat loop / public `ping(_:)`.
    public var pingCount: Int {
        stateLock.withLock { state in
            let list = state.events
            return list.reduce(0) { acc, event in
                if case .ping = event { return acc + 1 }
                return acc
            }
        }
    }

    /// Count of `.error(.pingTimeout)` events observed since the recorder
    /// started listening.
    public var pingTimeoutErrorCount: Int {
        stateLock.withLock { state in
            let list = state.events
            return list.reduce(0) { acc, event in
                if case .error(.pingTimeout) = event { return acc + 1 }
                return acc
            }
        }
    }

    /// Count of `.message(Data)` events observed.
    public var messageCount: Int {
        stateLock.withLock { state in
            let list = state.events
            return list.reduce(0) { acc, event in
                if case .message = event { return acc + 1 }
                return acc
            }
        }
    }

    /// Count of `.string(String)` events observed.
    public var stringCount: Int {
        stateLock.withLock { state in
            let list = state.events
            return list.reduce(0) { acc, event in
                if case .string = event { return acc + 1 }
                return acc
            }
        }
    }

    /// All `.error(_)` events observed, in order.
    public var errorEvents: [WebSocketError] {
        stateLock.withLock { state in
            let list = state.events
            return list.compactMap { event in
                if case .error(let err) = event { return err }
                return nil
            }
        }
    }

    public func waitForEvent(
        timeout: TimeInterval,
        matching predicate: @escaping @Sendable (WebSocketEvent) -> Bool
    ) async throws -> Bool {
        try Task.checkCancellation()
        if stateLock.withLock({ $0.events.contains(where: predicate) }) {
            return true
        }

        let id = UUID()
        let matched = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldWait = stateLock.withLock { state in
                    guard !state.events.contains(where: predicate) else { return false }
                    state.waiters.append(
                        EventWaiter(id: id, predicate: predicate, continuation: continuation)
                    )
                    return true
                }

                guard shouldWait else {
                    continuation.resume(returning: true)
                    return
                }

                scheduleTimeout(id: id, timeout: timeout)
            }
        } onCancel: {
            finishWaiter(id: id, result: .failure(CancellationError()))
        }
        try Task.checkCancellation()
        return matched
    }

    private func scheduleTimeout(id: UUID, timeout: TimeInterval) {
        let duration = max(timeout, 0)
        Task { [self] in
            let clock = ContinuousClock()
            do {
                try await clock.sleep(for: .seconds(duration))
            } catch {
                finishWaiter(id: id, result: .failure(error))
                return
            }
            finishWaiter(id: id, result: .success(false))
        }
    }

    private func finishWaiter(id: UUID, result: Result<Bool, Error>) {
        let continuation: CheckedContinuation<Bool, Error>? = stateLock.withLock { state in
            guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return state.waiters.remove(at: index).continuation
        }
        continuation?.resume(with: result)
    }
}
