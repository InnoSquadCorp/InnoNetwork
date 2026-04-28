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
    private let events = OSAllocatedUnfairLock<[WebSocketEvent]>(initialState: [])

    public init() {}

    public func record(_ event: WebSocketEvent) {
        events.withLock { $0.append(event) }
    }

    public func snapshot() -> [WebSocketEvent] {
        events.withLock { $0 }
    }

    public var pongCount: Int {
        events.withLock { list in
            list.reduce(0) { acc, event in
                if case .pong = event { return acc + 1 }
                return acc
            }
        }
    }

    /// All observed `.ping` contexts in order.
    public var pingContexts: [WebSocketPingContext] {
        events.withLock { list in
            list.compactMap { event in
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
        events.withLock { list in
            list.compactMap { event in
                if case .pong(let context) = event { return context }
                return nil
            }
        }
    }

    /// Count of `.ping` events observed since the recorder started listening.
    /// Paired with `pongCount` so tests can assert the `.ping → .pong` cadence
    /// emitted by the heartbeat loop / public `ping(_:)`.
    public var pingCount: Int {
        events.withLock { list in
            list.reduce(0) { acc, event in
                if case .ping = event { return acc + 1 }
                return acc
            }
        }
    }

    /// Count of `.error(.pingTimeout)` events observed since the recorder
    /// started listening.
    public var pingTimeoutErrorCount: Int {
        events.withLock { list in
            list.reduce(0) { acc, event in
                if case .error(.pingTimeout) = event { return acc + 1 }
                return acc
            }
        }
    }

    /// Count of `.message(Data)` events observed.
    public var messageCount: Int {
        events.withLock { list in
            list.reduce(0) { acc, event in
                if case .message = event { return acc + 1 }
                return acc
            }
        }
    }

    /// Count of `.string(String)` events observed.
    public var stringCount: Int {
        events.withLock { list in
            list.reduce(0) { acc, event in
                if case .string = event { return acc + 1 }
                return acc
            }
        }
    }

    /// All `.error(_)` events observed, in order.
    public var errorEvents: [WebSocketError] {
        events.withLock { list in
            list.compactMap { event in
                if case .error(let err) = event { return err }
                return nil
            }
        }
    }

    public func waitForEvent(
        timeout: TimeInterval,
        matching predicate: @Sendable (WebSocketEvent) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if events.withLock({ $0.contains(where: predicate) }) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return events.withLock { $0.contains(where: predicate) }
    }
}
