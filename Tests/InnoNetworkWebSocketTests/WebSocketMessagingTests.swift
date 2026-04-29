import Foundation
import Testing

@testable import InnoNetworkWebSocket

@Suite("WebSocket Messaging Tests")
struct WebSocketMessagingTests {

    @Test("send(data:) on disconnected task throws .disconnected")
    func sendDataOnDisconnectedThrows() async {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: makeWebSocketTestSessionIdentifier("send-data-disconnected")
            )
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)

        await #expect(throws: WebSocketError.self) {
            try await manager.send(task, message: Data("hello".utf8))
        }
    }

    @Test("send(string:) on disconnected task throws .disconnected")
    func sendStringOnDisconnectedThrows() async {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: makeWebSocketTestSessionIdentifier("send-string-disconnected")
            )
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)

        await #expect(throws: WebSocketError.self) {
            try await manager.send(task, string: "hello")
        }
    }

    @Test("ping on disconnected task throws .disconnected")
    func pingOnDisconnectedThrows() async {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: makeWebSocketTestSessionIdentifier("ping-disconnected")
            )
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)

        await #expect(throws: WebSocketError.self) {
            try await manager.ping(task)
        }
    }

    @Test("send after manager removes task runtime throws .disconnected")
    func sendAfterRuntimeRemovedThrows() async throws {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: makeWebSocketTestSessionIdentifier("send-post-disconnect")
            )
        )

        let task = await manager.connect(url: URL(string: "wss://example.invalid/socket")!)
        let identifier = try #require(await waitForWebSocketRuntimeTaskIdentifier(manager: manager, task: task))
        manager.handleDisconnected(taskIdentifier: identifier, closeCode: .normalClosure, reason: nil)

        #expect(await waitForWebSocketTaskRemoval(manager: manager, task: task))

        await #expect(throws: WebSocketError.self) {
            try await manager.send(task, message: Data("after-close".utf8))
        }
    }
}
