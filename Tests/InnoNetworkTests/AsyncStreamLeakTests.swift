import Foundation
import Testing

@testable import InnoNetwork

/// Regression tests for hardening item 1-3: AsyncStream `onTermination`
/// closures must not strongly capture their enclosing actor. A strong
/// capture forms a retain cycle when the consumer holds the stream and the
/// stream's termination handler holds the actor — under network flapping
/// this leaks one actor per disconnection and prevents `deinit` from ever
/// running.
@Suite("AsyncStream onTermination weak-self leak guards")
struct AsyncStreamLeakTests {

    @Test("TaskEventHub releases after the only strong reference drops")
    func taskEventHubDeinitsAfterStreamTakeover() async {
        weak var weakHub: TaskEventHub<Int>?
        var capturedStream: AsyncStream<Int>?

        do {
            let hub = TaskEventHub<Int>()
            weakHub = hub
            // Allocate a stream consumer slot — this is the path that wires
            // `onTermination` to the hub. If the closure retained `self`
            // strongly, the hub would survive the `do` block via the stream
            // we hold below.
            capturedStream = await hub.stream(for: "leak-probe")
        }

        #expect(capturedStream != nil)
        // Drop the stream so its continuation terminates and the
        // onTermination closure can fire without keeping the hub alive.
        capturedStream = nil

        // Allow the deferred onTermination Task to settle. A short suspending
        // sleep is more reliable than a fixed `Task.yield()` count under CI
        // load — the termination Task must hop to an actor executor before
        // the weak reference drops, and 5 cooperative yields can be too few.
        try? await Task.sleep(for: .milliseconds(100), clock: .suspending)

        #expect(weakHub == nil)
    }

    @Test("NetworkMonitor releases after the only strong reference drops")
    func networkMonitorDeinitsAfterWaitForChange() async {
        weak var weakMonitor: NetworkMonitor?

        do {
            let monitor = NetworkMonitor()
            weakMonitor = monitor
            // `waitForChange` internally creates an `updates()` AsyncStream
            // whose continuation has the onTermination handler under test.
            // A short timeout ensures the call returns without blocking and
            // the stream is dropped before we exit the scope.
            _ = await monitor.waitForChange(from: nil, timeout: 0.01)
            await monitor.stop()
        }

        // Same rationale as `taskEventHubDeinitsAfterStreamTakeover`: a
        // suspending sleep is more reliable than a fixed `Task.yield()`
        // count under CI load. The deferred `removeContinuation` Task must
        // hop to the monitor's actor executor before the weak reference
        // can drop.
        try? await Task.sleep(for: .milliseconds(200), clock: .suspending)

        #expect(weakMonitor == nil)
    }
}
