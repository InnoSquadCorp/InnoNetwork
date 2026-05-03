import InnoNetworkTestSupport
import Testing

@Suite("TestClock signaling")
struct TestClockTests {

    @Test("waitForWaiters wakes as soon as a sleep waiter is registered")
    func waitForWaitersWakesOnSleepRegistration() async {
        let clock = TestClock()

        async let reached = clock.waitForWaiters(count: 1)
        let sleeper = Task {
            try await clock.sleep(for: .seconds(10))
        }

        #expect(await reached)

        sleeper.cancel()
        await #expect(throws: CancellationError.self) {
            try await sleeper.value
        }
    }

    @Test("waitForEnqueuedCount wakes as soon as a new sleep is enqueued")
    func waitForEnqueuedCountWakesOnSleepRegistration() async throws {
        let clock = TestClock()
        let target = clock.enqueuedCount + 1

        async let reached = clock.waitForEnqueuedCount(atLeast: target)
        let sleeper = Task {
            try await clock.sleep(for: .seconds(2))
        }

        #expect(await reached)

        clock.advance(by: .seconds(2))
        try await sleeper.value
    }

    @Test("condition waits time out when no matching signal arrives")
    func conditionWaitTimesOut() async {
        let clock = TestClock()

        #expect(await clock.waitForWaiters(count: 1, timeout: 0.01) == false)
    }
}
