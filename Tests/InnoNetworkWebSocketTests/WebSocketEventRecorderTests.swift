import Foundation
import InnoNetworkTestSupport
import InnoNetworkWebSocket
import Testing

@Suite("WebSocketEventRecorder signaling")
struct WebSocketEventRecorderTests {

    @Test("waitForEvent wakes when a matching event is recorded")
    func waitForEventWakesOnRecord() async throws {
        let recorder = WebSocketEventRecorder()

        async let matched = recorder.waitForEvent(timeout: 1.0) { event in
            if case .string("ready") = event { return true }
            return false
        }

        recorder.record(.string("ready"))

        #expect(try await matched)
    }

    @Test("waitForEvent returns false when no matching event arrives before timeout")
    func waitForEventTimesOut() async throws {
        let recorder = WebSocketEventRecorder()

        let matched = try await recorder.waitForEvent(timeout: 0.01) { event in
            if case .string("never") = event { return true }
            return false
        }

        #expect(matched == false)
    }

    @Test("waitForEvent propagates cancellation")
    func waitForEventPropagatesCancellation() async {
        let recorder = WebSocketEventRecorder()
        let waiter = Task {
            try await recorder.waitForEvent(timeout: 10.0) { event in
                if case .string("never") = event { return true }
                return false
            }
        }

        waiter.cancel()

        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
    }
}
