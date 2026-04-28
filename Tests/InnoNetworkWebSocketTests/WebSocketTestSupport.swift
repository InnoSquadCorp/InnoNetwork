import Foundation

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
