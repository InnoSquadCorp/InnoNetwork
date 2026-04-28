import Foundation
import Testing
import InnoNetwork
import InnoNetworkWebSocket


@Suite("Postman Echo Live Tests")
struct PostmanEchoLiveTests {

    @Test("WebSocket echoes a string payload back to the sender", .liveOnly)
    func websocketEchoesString() async throws {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: "test.live.postman.\(UUID().uuidString)"
            )
        )

        do {
            try await runWebSocketEchoScenario(manager: manager)
        } catch {
            await manager.disconnectAll()
            throw error
        }
        await manager.disconnectAll()
    }

    private func runWebSocketEchoScenario(manager: WebSocketManager) async throws {
        let url = try #require(URL(string: "wss://ws.postman-echo.com/raw"))
        let task = await manager.connect(url: url)

        // Wait briefly for the handshake to complete. Live tests are
        // intentionally generous on timing because postman-echo can be slow.
        for _ in 0..<200 {
            if await task.state == .connected { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try #require(await task.state == .connected, "WebSocket failed to reach .connected within 10s")

        let payload = "innonetwork-live-\(UUID().uuidString)"

        // Subscribe before sending so we don't miss the echoed message.
        let collector = EchoCollector()
        let stream = await manager.events(for: task)
        let consumer = Task {
            for await event in stream {
                if case .string(let value) = event {
                    await collector.set(value)
                    return
                }
            }
        }

        try await manager.send(task, string: payload)

        // Wait up to 10s for the echo.
        for _ in 0..<200 {
            if await collector.value != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        consumer.cancel()
        let echoed = await collector.value
        #expect(echoed == payload, "Postman echo did not return the payload within 10s")
    }
}


private actor EchoCollector {
    private(set) var value: String?

    func set(_ value: String) {
        if self.value == nil { self.value = value }
    }
}
