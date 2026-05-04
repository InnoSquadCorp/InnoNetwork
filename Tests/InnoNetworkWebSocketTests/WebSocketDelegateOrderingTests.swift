import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetworkWebSocket

/// Regression coverage for the single-consumer `AsyncStream` that
/// serializes `URLSession` delegate callbacks. Prior to C12 each `handle*`
/// entry point spawned its own `Task`, so a back-to-back
/// `handleConnected → handleDisconnected` could be reordered on the
/// cooperative thread pool. The serialized consumer guarantees that
/// listeners observe the lifecycle in arrival order.
@Suite("WebSocket Delegate Ordering Tests")
struct WebSocketDelegateOrderingTests {

    @Test("Connected → disconnected callbacks deliver events in arrival order")
    func connectedThenDisconnectedDeliversInOrder() async throws {
        let harness = StubMessagingHarness()
        let task = await harness.manager.connect(url: URL(string: "ws://stub.invalid/ordering")!)

        let recorder = WebSocketEventRecorder()
        _ = await harness.manager.addEventListener(for: task) { event in
            recorder.record(event)
        }

        // Fire both callbacks back-to-back from the same synchronous frame.
        // Without the serialized consumer this race could surface
        // `disconnected` ahead of `connected` for a fresh task.
        harness.manager.handleConnected(taskIdentifier: harness.stubTaskIdentifier, protocolName: nil)
        harness.manager.handleDisconnected(
            taskIdentifier: harness.stubTaskIdentifier,
            closeCode: .normalClosure,
            reason: nil
        )

        let observed = try await recorder.waitForEvent(timeout: 2.0) { event in
            if case .disconnected = event { return true }
            return false
        }
        #expect(observed)

        let lifecycleEvents = recorder.snapshot().compactMap { event -> String? in
            switch event {
            case .connected: return "connected"
            case .disconnected: return "disconnected"
            default: return nil
            }
        }
        let connectedIndex = lifecycleEvents.firstIndex(of: "connected")
        let disconnectedIndex = lifecycleEvents.firstIndex(of: "disconnected")
        #expect(connectedIndex != nil)
        #expect(disconnectedIndex != nil)
        if let connectedIndex, let disconnectedIndex {
            #expect(connectedIndex < disconnectedIndex)
        }
    }

    @Test("Repeated connected/disconnected pairs preserve FIFO order")
    func repeatedPairsPreserveFIFO() async throws {
        let harness = StubMessagingHarness()
        let task = await harness.manager.connect(url: URL(string: "ws://stub.invalid/fifo")!)

        let recorder = WebSocketEventRecorder()
        _ = await harness.manager.addEventListener(for: task) { event in
            recorder.record(event)
        }

        // Drive several connect/disconnect cycles. Each observed pair
        // must arrive in order so that the lifecycle event sequence
        // interleaves connected, disconnected, connected, disconnected,
        // ... rather than landing in a Task-pool-determined ordering.
        // Subsequent cycles may be dropped once the registry removes
        // the task on the first `.normalClosure`; the assertion only
        // checks that no inverted pair surfaces.
        for _ in 0..<5 {
            harness.manager.handleConnected(
                taskIdentifier: harness.stubTaskIdentifier,
                protocolName: nil
            )
            harness.manager.handleDisconnected(
                taskIdentifier: harness.stubTaskIdentifier,
                closeCode: .normalClosure,
                reason: nil
            )
        }

        // Wait until the consumer Task drains the queue. Subsequent
        // cycles after the first close may be dropped by the registry
        // (the stub task is removed on .normalClosure), so we just
        // confirm at least one (connected, disconnected) pair lands.
        _ = try await recorder.waitForEvent(timeout: 1.0) { event in
            if case .disconnected = event { return true }
            return false
        }
        let lifecycle = recorder.snapshot().compactMap { event -> String? in
            switch event {
            case .connected: return "connected"
            case .disconnected: return "disconnected"
            default: return nil
            }
        }

        // Guard the FIFO check with concrete pair-presence assertions so
        // the test can never pass on a single `.disconnected` without a
        // matching `.connected` ahead of it. Without these, the loop below
        // simply never executes when `lifecycle.count <= 1`.
        #expect(lifecycle.count >= 2)
        #expect(lifecycle.first == "connected")
        #expect(lifecycle.dropFirst().first == "disconnected")

        // Each consecutive pair must be (connected, disconnected) — never
        // a doubled disconnected before its connected.
        var index = 0
        while index < lifecycle.count - 1 {
            if lifecycle[index] == "connected", lifecycle[index + 1] == "disconnected" {
                index += 2
                continue
            }
            // Allow trailing tail (e.g., extra connected captured before
            // its paired disconnected drains) but never an inverted pair.
            #expect(lifecycle[index] != "disconnected" || lifecycle[index + 1] != "connected")
            index += 1
        }
    }
}
