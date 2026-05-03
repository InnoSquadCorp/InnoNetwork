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

    @Test("send and ping while connecting are rejected without URL task side effects")
    func sendAndPingWhileConnectingAreRejected() async throws {
        let harness = StubMessagingHarness()
        let task = await harness.manager.connect(url: URL(string: "ws://stub.invalid/socket")!)

        #expect(await task.state == .connecting)

        await #expect(throws: WebSocketError.self) {
            try await harness.manager.send(task, message: Data("not-open".utf8))
        }
        await #expect(throws: WebSocketError.self) {
            try await harness.manager.send(task, string: "not-open")
        }
        await #expect(throws: WebSocketError.self) {
            try await harness.manager.ping(task)
        }

        #expect(harness.stubTask.sentMessages.isEmpty)
        #expect(harness.stubTask.pingCount == 0)
        #expect(await task.inFlightSendCount == 0)

        await harness.tearDown(task: task)
    }

    @Test("send and ping while disconnecting are rejected without URL task side effects")
    func sendAndPingWhileDisconnectingAreRejected() async throws {
        let harness = StubMessagingHarness(closeHandshakeTimeout: .seconds(30))
        let task = try await harness.connectAndReady()

        await harness.manager.disconnect(task)

        #expect(await harness.waitForTaskState(task, equals: .disconnecting))

        await #expect(throws: WebSocketError.self) {
            try await harness.manager.send(task, message: Data("closing".utf8))
        }
        await #expect(throws: WebSocketError.self) {
            try await harness.manager.send(task, string: "closing")
        }
        await #expect(throws: WebSocketError.self) {
            try await harness.manager.ping(task)
        }

        #expect(harness.stubTask.sentMessages.isEmpty)
        #expect(harness.stubTask.pingCount == 0)
        #expect(await task.inFlightSendCount == 0)

        harness.manager.handleDisconnected(
            taskIdentifier: harness.stubTaskIdentifier,
            closeCode: .normalClosure,
            reason: nil
        )
        #expect(await waitForWebSocketTaskRemoval(manager: harness.manager, task: task))
    }
}
