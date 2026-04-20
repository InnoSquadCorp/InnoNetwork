import Foundation
import os
import Testing
@testable import InnoNetwork


@Suite("RetryCoordinator Timing Tests")
struct RetryCoordinatorTimingTests {

    @Test("retryDelay > 0 suspends on the injected clock until advance")
    func retrySleepUsesInjectedClock() async throws {
        let clock = TestClock()
        let eventHub = NetworkEventHub()
        let coordinator = RetryCoordinator(eventHub: eventHub, clock: clock)

        let attemptCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
        let policy = FixedDelayRetryPolicy(maxRetries: 3, retryDelay: 2.0)

        async let result: Int = coordinator.execute(
            retryPolicy: policy,
            networkMonitor: nil,
            requestID: UUID(),
            eventObservers: []
        ) { _, _ in
            let attempt = attemptCounter.withLock { count -> Int in
                count += 1
                return count
            }
            if attempt < 3 {
                throw NetworkError.underlying(
                    SendableUnderlyingError(
                        domain: "Test",
                        code: 0,
                        message: "transient-\(attempt)"
                    ),
                    nil
                )
            }
            return 42
        }

        // Attempt 1 fails -> coordinator enqueues first clock.sleep(2.0)
        #expect(await clock.waitForWaiters(count: 1))
        #expect(attemptCounter.withLock { $0 } == 1)

        // Advance first retry delay -> attempt 2 runs, fails, enqueues next sleep
        clock.advance(by: .seconds(2))
        #expect(await clock.waitForEnqueuedCount(atLeast: 2))
        #expect(attemptCounter.withLock { $0 } == 2)

        // Advance second retry delay -> attempt 3 runs, succeeds
        clock.advance(by: .seconds(2))

        let value = try await result
        #expect(value == 42)
        #expect(attemptCounter.withLock { $0 } == 3)
    }

    @Test("retryDelay == 0 skips clock.sleep entirely")
    func noSleepWhenDelayZero() async throws {
        let clock = TestClock()
        let eventHub = NetworkEventHub()
        let coordinator = RetryCoordinator(eventHub: eventHub, clock: clock)

        let attemptCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
        let policy = FixedDelayRetryPolicy(maxRetries: 2, retryDelay: 0)

        let result: Int = try await coordinator.execute(
            retryPolicy: policy,
            networkMonitor: nil,
            requestID: UUID(),
            eventObservers: []
        ) { _, _ in
            let attempt = attemptCounter.withLock { count -> Int in
                count += 1
                return count
            }
            if attempt == 1 {
                throw NetworkError.underlying(
                    SendableUnderlyingError(
                        domain: "Test",
                        code: 0,
                        message: "first"
                    ),
                    nil
                )
            }
            return 7
        }

        // No advance calls -- the sleep path was never taken.
        #expect(result == 7)
        #expect(clock.enqueuedCount == 0)
        #expect(attemptCounter.withLock { $0 } == 2)
    }

    @Test("Cumulative retry delays sum across attempts")
    func cumulativeRetryDelaysUseClockAdvance() async throws {
        let clock = TestClock()
        let eventHub = NetworkEventHub()
        let coordinator = RetryCoordinator(eventHub: eventHub, clock: clock)

        let attemptCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
        let policy = FixedDelayRetryPolicy(maxRetries: 4, retryDelay: 3.0)

        async let result: Int = coordinator.execute(
            retryPolicy: policy,
            networkMonitor: nil,
            requestID: UUID(),
            eventObservers: []
        ) { _, _ in
            let attempt = attemptCounter.withLock { count -> Int in
                count += 1
                return count
            }
            if attempt < 4 {
                throw NetworkError.underlying(
                    SendableUnderlyingError(
                        domain: "Test",
                        code: 0,
                        message: "attempt-\(attempt)"
                    ),
                    nil
                )
            }
            return 100
        }

        for cycle in 1...3 {
            #expect(await clock.waitForEnqueuedCount(atLeast: cycle))
            clock.advance(by: .seconds(3))
            #expect(await clock.waitForEnqueuedCount(atLeast: cycle + 1) || cycle == 3)
        }

        let value = try await result
        #expect(value == 100)
        #expect(attemptCounter.withLock { $0 } == 4)
    }
}


/// Minimal RetryPolicy used by the timing tests so the retry semantics stay
/// orthogonal to the clock behavior under test. Always retries up to
/// `maxRetries`, with a fixed `retryDelay` across attempts.
private struct FixedDelayRetryPolicy: RetryPolicy {
    let maxRetries: Int
    let retryDelay: TimeInterval

    func shouldRetry(error: NetworkError, retryIndex: Int) -> Bool {
        retryIndex < maxRetries
    }
}
