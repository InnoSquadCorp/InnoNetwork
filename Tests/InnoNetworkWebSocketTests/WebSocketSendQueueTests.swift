import Foundation
import Testing

@testable import InnoNetworkWebSocket

@Suite("WebSocket Send Queue Tests")
struct WebSocketSendQueueTests {

    // MARK: - WebSocketTask slot semantics

    @Test("tryReserveSendSlot grants slots up to limit")
    func reserveGrantsUpToLimit() async {
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)
        let limit = 4

        for index in 0..<limit {
            let granted = await task.tryReserveSendSlot(limit: limit)
            #expect(granted, "Slot \(index) within limit must succeed")
        }
        #expect(await task.inFlightSendCount == limit)
    }

    @Test("tryReserveSendSlot refuses past limit and refusal does not bump the counter")
    func reserveRefusesPastLimit() async {
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)
        let limit = 2

        _ = await task.tryReserveSendSlot(limit: limit)
        _ = await task.tryReserveSendSlot(limit: limit)
        let third = await task.tryReserveSendSlot(limit: limit)

        #expect(third == false)
        #expect(await task.inFlightSendCount == limit)
    }

    @Test("releaseSendSlot decrements but never goes below zero")
    func releaseClampsAtZero() async {
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)
        await task.releaseSendSlot()
        await task.releaseSendSlot()
        #expect(await task.inFlightSendCount == 0)

        _ = await task.tryReserveSendSlot(limit: 5)
        await task.releaseSendSlot()
        #expect(await task.inFlightSendCount == 0)
    }

    @Test("reset() clears the in-flight send counter")
    func resetClearsInFlight() async {
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)
        _ = await task.tryReserveSendSlot(limit: 8)
        _ = await task.tryReserveSendSlot(limit: 8)
        #expect(await task.inFlightSendCount == 2)

        await task.reset()
        #expect(await task.inFlightSendCount == 0)
    }

    // MARK: - WebSocketManager.send overflow integration

    @Test("send(message:) on a saturated queue with .fail throws sendQueueOverflow")
    func sendFailsOnOverflow() async throws {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: makeWebSocketTestSessionIdentifier("send-overflow-fail"),
                sendQueueLimit: 2,
                sendQueueOverflowPolicy: .fail
            )
        )
        let url = URL(string: "wss://example.invalid/socket")!
        let task = WebSocketTask(url: url)
        await manager.runtimeRegistry.add(task)
        let stub = StubWebSocketURLTask()
        await manager.runtimeRegistry.setURLTask(stub, for: task.id)
        await task.restoreStateForTesting(.connected)

        // Pre-saturate the slot counter to mimic two in-flight sends.
        _ = await task.tryReserveSendSlot(limit: 2)
        _ = await task.tryReserveSendSlot(limit: 2)

        do {
            try await manager.send(task, message: Data("hello".utf8))
            Issue.record("Expected sendQueueOverflow")
        } catch let error as WebSocketError {
            switch error {
            case .sendQueueOverflow(let reportedLimit):
                #expect(reportedLimit == 2)
            default:
                Issue.record("Expected .sendQueueOverflow, got \(error)")
            }
        }

        #expect(await task.inFlightSendCount == 2)
    }

    @Test("send(message:) on a saturated queue with .dropNewest returns silently")
    func sendDropsOnOverflow() async throws {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: makeWebSocketTestSessionIdentifier("send-overflow-drop"),
                sendQueueLimit: 1,
                sendQueueOverflowPolicy: .dropNewest
            )
        )
        let url = URL(string: "wss://example.invalid/socket")!
        let task = WebSocketTask(url: url)
        await manager.runtimeRegistry.add(task)
        let stub = StubWebSocketURLTask()
        await manager.runtimeRegistry.setURLTask(stub, for: task.id)
        await task.restoreStateForTesting(.connected)

        // Saturate the queue.
        _ = await task.tryReserveSendSlot(limit: 1)

        // The send must NOT throw and must NOT consume an additional slot.
        try await manager.send(task, message: Data("hello".utf8))
        #expect(await task.inFlightSendCount == 1, "Drop must not occupy a slot")
    }

    @Test("Successful send releases its slot")
    func successfulSendReleasesSlot() async throws {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: makeWebSocketTestSessionIdentifier("send-overflow-release"),
                sendQueueLimit: 4,
                sendQueueOverflowPolicy: .fail
            )
        )
        let url = URL(string: "wss://example.invalid/socket")!
        let task = WebSocketTask(url: url)
        await manager.runtimeRegistry.add(task)
        let stub = StubWebSocketURLTask()
        await manager.runtimeRegistry.setURLTask(stub, for: task.id)
        await task.restoreStateForTesting(.connected)

        try await manager.send(task, message: Data("hello".utf8))
        #expect(await task.inFlightSendCount == 0)
    }
}
