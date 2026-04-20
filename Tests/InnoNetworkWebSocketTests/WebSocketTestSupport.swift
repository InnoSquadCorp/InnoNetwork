import Foundation
import os
@testable import InnoNetworkWebSocket


/// Produces a unique sessionIdentifier for a WebSocket test.
func makeWebSocketTestSessionIdentifier(_ label: String) -> String {
    "test.websocket.\(label).\(UUID().uuidString)"
}


/// Waits for the manager runtime to assign a WebSocket task identifier.
func waitForWebSocketRuntimeTaskIdentifier(
    manager: WebSocketManager,
    task: WebSocketTask,
    excluding: Set<Int> = [],
    timeout: TimeInterval = 2.0
) async -> Int? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let identifier = await manager.runtimeTaskIdentifier(for: task), !excluding.contains(identifier) {
            return identifier
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return nil
}


/// Waits for `task.state` to satisfy `predicate`.
func waitForWebSocketState(
    _ task: WebSocketTask,
    timeout: TimeInterval = 2.0,
    predicate: @escaping @Sendable (WebSocketState) -> Bool
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


/// Waits for the task to be removed from the manager's registry.
func waitForWebSocketTaskRemoval(
    manager: WebSocketManager,
    task: WebSocketTask,
    timeout: TimeInterval = 2.0
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await manager.task(withId: task.id) == nil {
            return true
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return false
}


// MARK: - Event recorder

/// Collects `WebSocketEvent` values published through `TaskEventHub` for
/// assertion in multi-cycle timing/reconnect/receive tests. Originally lived
/// inside `WebSocketHeartbeatTimingTests` as `HeartbeatEventRecorder`; moved
/// here so Messaging / Reconnect / ReceiveLoop suites can reuse the same
/// snapshot and counter helpers.
///
/// Thread safety: `OSAllocatedUnfairLock` guards the internal event buffer,
/// so the recorder is safe to call from event-hub listener closures (which
/// run on arbitrary background tasks).
final class WebSocketEventRecorder: Sendable {
    private let events = OSAllocatedUnfairLock<[WebSocketEvent]>(initialState: [])

    func record(_ event: WebSocketEvent) {
        events.withLock { $0.append(event) }
    }

    func snapshot() -> [WebSocketEvent] {
        events.withLock { $0 }
    }

    var pongCount: Int {
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
    var pingCount: Int {
        events.withLock { list in
            list.reduce(0) { acc, event in
                if case .ping = event { return acc + 1 }
                return acc
            }
        }
    }

    /// Count of `.error(.pingTimeout)` events observed since the recorder
    /// started listening.
    var pingTimeoutErrorCount: Int {
        events.withLock { list in
            list.reduce(0) { acc, event in
                if case .error(.pingTimeout) = event { return acc + 1 }
                return acc
            }
        }
    }

    /// Count of `.message(Data)` events observed.
    var messageCount: Int {
        events.withLock { list in
            list.reduce(0) { acc, event in
                if case .message = event { return acc + 1 }
                return acc
            }
        }
    }

    /// Count of `.string(String)` events observed.
    var stringCount: Int {
        events.withLock { list in
            list.reduce(0) { acc, event in
                if case .string = event { return acc + 1 }
                return acc
            }
        }
    }

    /// All `.error(_)` events observed, in order.
    var errorEvents: [WebSocketError] {
        events.withLock { list in
            list.compactMap { event in
                if case .error(let err) = event { return err }
                return nil
            }
        }
    }

    func waitForEvent(
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


/// Back-compat alias so the heartbeat timing suite keeps compiling during
/// the incremental migration away from the heartbeat-specific name. Newer
/// suites should use `WebSocketEventRecorder` directly.
typealias HeartbeatEventRecorder = WebSocketEventRecorder
