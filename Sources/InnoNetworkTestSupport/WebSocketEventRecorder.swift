import Foundation
import os
import InnoNetworkWebSocket


/// Collects `WebSocketEvent` values published through `TaskEventHub` for
/// assertion in multi-cycle timing / reconnect / receive / messaging tests.
///
/// Thread safety: `OSAllocatedUnfairLock` guards the internal event buffer,
/// so the recorder is safe to call from event-hub listener closures (which
/// run on arbitrary background tasks).
package final class WebSocketEventRecorder: Sendable {
    private let events = OSAllocatedUnfairLock<[WebSocketEvent]>(initialState: [])

    package init() {}

    package func record(_ event: WebSocketEvent) {
        events.withLock { $0.append(event) }
    }

    package func snapshot() -> [WebSocketEvent] {
        events.withLock { $0 }
    }

    package var pongCount: Int {
        events.withLock { list in
            list.reduce(0) { acc, event in
                if case .pong = event { return acc + 1 }
                return acc
            }
        }
    }

    /// Count of `.ping` events observed since the recorder started listening.
    /// Paired with `pongCount` so tests can assert the `.ping → .pong` cadence
    /// emitted by the heartbeat loop / public `ping(_:)`.
    package var pingCount: Int {
        events.withLock { list in
            list.reduce(0) { acc, event in
                if case .ping = event { return acc + 1 }
                return acc
            }
        }
    }

    /// Count of `.error(.pingTimeout)` events observed since the recorder
    /// started listening.
    package var pingTimeoutErrorCount: Int {
        events.withLock { list in
            list.reduce(0) { acc, event in
                if case .error(.pingTimeout) = event { return acc + 1 }
                return acc
            }
        }
    }

    /// Count of `.message(Data)` events observed.
    package var messageCount: Int {
        events.withLock { list in
            list.reduce(0) { acc, event in
                if case .message = event { return acc + 1 }
                return acc
            }
        }
    }

    /// Count of `.string(String)` events observed.
    package var stringCount: Int {
        events.withLock { list in
            list.reduce(0) { acc, event in
                if case .string = event { return acc + 1 }
                return acc
            }
        }
    }

    /// All `.error(_)` events observed, in order.
    package var errorEvents: [WebSocketError] {
        events.withLock { list in
            list.compactMap { event in
                if case .error(let err) = event { return err }
                return nil
            }
        }
    }

    package func waitForEvent(
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
