import Foundation
import Testing

@testable import InnoNetwork

@Suite("NetworkMonitor lifecycle")
struct NetworkMonitorLifecycleTests {

    @Test("start() then stop() then start() recycles the underlying NWPathMonitor")
    func startStopStart() async throws {
        let monitor = NetworkMonitor()

        // First start: should not block, idempotent on repeated calls.
        await monitor.start()
        await monitor.start()
        // First stop: tears down the active monitor and consumer task.
        await monitor.stop()
        // Second stop: idempotent no-op.
        await monitor.stop()
        // Re-start after stop: must succeed without crashing because the
        // storage layer recreates a fresh NWPathMonitor.
        await monitor.start()

        // Probe an API to confirm the actor still responds normally.
        // currentSnapshot may legitimately return nil if the platform has not
        // emitted any path updates yet — the lifecycle invariant we care
        // about is just "no crash and the actor remains responsive".
        _ = await monitor.currentSnapshot()
        await monitor.stop()
    }
}


@Suite("EventDeliveryPolicy default buffer")
struct EventDeliveryPolicyDefaultTests {

    @Test("Defaults grew to 256 events for bursty event traffic")
    func defaultBufferGrew() {
        let policy = EventDeliveryPolicy.default
        #expect(policy.maxBufferedEventsPerPartition == 256)
        #expect(policy.maxBufferedEventsPerConsumer == 256)
        #expect(policy.overflowPolicy == .dropOldest)
    }
}

extension EventPipelineOverflowPolicy: Swift.Equatable {
    public static func == (lhs: EventPipelineOverflowPolicy, rhs: EventPipelineOverflowPolicy) -> Bool {
        switch (lhs, rhs) {
        case (.dropOldest, .dropOldest), (.dropNewest, .dropNewest):
            return true
        default:
            return false
        }
    }
}
