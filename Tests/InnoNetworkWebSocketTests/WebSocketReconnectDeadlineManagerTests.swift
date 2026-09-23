import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkWebSocket

extension WebSocketManagerShutdownTests {
    @Test(
        "A reconnect deadline terminates the manager task without creating another transport", .timeLimit(.minutes(1)),
        arguments: [false, true])
    func reconnectDeadlineCleansUpManagerTask(adapterExhaustsWindow: Bool) async throws {
        let clock = TestClock()
        let adaptations = OSAllocatedUnfairLock<Int>(initialState: 0)
        let harness = makeShutdownHarness(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0, reconnectDelay: adapterExhaustsWindow ? 1 : 10, reconnectJitterRatio: 0,
                maxReconnectAttempts: 10, reconnectMaxTotalDuration: 5,
                handshakeRequestAdapters: [
                    WebSocketHandshakeRequestAdapter { request in
                        let call = adaptations.withLock {
                            $0 += 1
                            return $0
                        }
                        if adapterExhaustsWindow, call > 1 { clock.advance(by: .seconds(6)) }
                        return request
                    }
                ]
            ), clock: clock
        )
        let task = await harness.manager.connect(
            url: try #require(URL(string: "wss://example.invalid/manager-deadline")))
        let identifier = try #require(await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task))
        let events = await harness.manager.events(for: task)
        let collector = Task {
            var errors = 0
            for await event in events {
                if case .error(.reconnectWindowExceeded) = event { errors += 1 }
            }
            return errors
        }
        harness.manager.handleDisconnected(taskIdentifier: identifier, closeCode: .goingAway, reason: nil)
        try #require(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(adapterExhaustsWindow ? 1 : 5))
        #expect(await collector.value == 1)
        #expect(await task.state == .failed)
        #expect(harness.session.createdTasks.count == 1)
        #expect(await harness.manager.runtimeTaskIdentifier(for: task) == nil)
        #expect(clock.waiterCount == 0)
        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }
}
