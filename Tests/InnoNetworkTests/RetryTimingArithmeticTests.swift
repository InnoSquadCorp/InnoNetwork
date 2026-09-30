import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork

@Suite("Retry delay arithmetic", .timeLimit(.minutes(1)))
struct RetryTimingArithmeticTests {
    @Test func hugeFiniteJitterDoesNotCreateInfiniteRandomRange() {
        let policy = ExponentialBackoffRetryPolicy(retryDelay: 30, jitterRatio: 1e308)
        for sample in [-1.0, -0.001, 0, 0.001, 1] {
            let delay = policy.retryDelay(for: 0, unitJitter: sample)
            #expect(delay.isFinite && delay >= 0)
        }
        #expect(policy.retryDelay(for: 0, unitJitter: 1) == .greatestFiniteMagnitude)
        #expect(policy.retryDelay(for: 0, unitJitter: -1) == 0)
        for _ in 0..<128 { #expect(policy.retryDelay(for: Int.max).isFinite) }
    }

    @Test(arguments: [0.0, 0.2, 2, -0.2])
    func supportedJitterAndBaseCapRemainCompatible(ratio: Double) {
        let policy = ExponentialBackoffRetryPolicy(retryDelay: 30, maxDelay: 30, jitterRatio: ratio)
        #expect(policy.retryDelay(for: 0, unitJitter: 0) == 30)
        #expect(policy.retryDelay(for: 100, unitJitter: 1) == 30 + 30 * abs(ratio))
        #expect(policy.retryDelay(for: 0, unitJitter: -1) == max(0, 30 - 30 * abs(ratio)))
        #expect(ExponentialBackoffRetryPolicy(retryDelay: 0).retryDelay(for: Int.max) == 0)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func directInvalidInputsRemainNonthrowingAndFinite(value: Double) {
        #expect(ExponentialBackoffRetryPolicy(retryDelay: value).retryDelay(for: 0) == 0)
        #expect(ExponentialBackoffRetryPolicy(maxDelay: value).retryDelay(for: 0) == 0)
        #expect(ExponentialBackoffRetryPolicy(jitterRatio: value).retryDelay(for: 0) == 0)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func invalidPolicyCannotDispatch(value: Double) async {
        let coordinator = RetryCoordinator(eventHub: NetworkEventHub())
        let calls = OSAllocatedUnfairLock(initialState: 0)
        for policy in [
            ExponentialBackoffRetryPolicy(retryDelay: value),
            ExponentialBackoffRetryPolicy(maxDelay: value),
            ExponentialBackoffRetryPolicy(jitterRatio: value),
            ExponentialBackoffRetryPolicy(networkChangeTimeout: value),
        ] {
            do {
                let _: Int = try await coordinator.execute(
                    retryPolicy: policy, networkMonitor: nil,
                    requestID: UUID(), eventObservers: [],
                    operation: { _, _ in
                        calls.withLock { $0 += 1 }
                        return 1
                    })
                Issue.record("Expected invalid configuration")
            } catch {
                guard case .configuration = error as? NetworkError else {
                    Issue.record(error)
                    return
                }
            }
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func invalidComputedDelayCannotStartAnotherAttempt(value: Double) async {
        let clock = TestClock()
        let coordinator = RetryCoordinator(eventHub: NetworkEventHub(), clock: clock)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let request = URLRequest(url: URL(string: "https://example.test/retry")!)
        do {
            let _: Int = try await coordinator.execute(
                retryPolicy: InvalidComputedDelayPolicy(delay: value), networkMonitor: nil,
                requestID: UUID(), eventObservers: [],
                operation: { _, _ in
                    calls.withLock { $0 += 1 }
                    throw RequestExecutionFailure(error: .timeout(reason: .requestTimeout), request: request)
                })
            Issue.record("Expected invalid computed delay")
        } catch {
            guard case .configuration = error as? NetworkError else {
                Issue.record(error)
                return
            }
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(clock.waiterCount == 0)
    }

    @Test func hugeFiniteBackoffKeepsOneAttemptUntilCancelled() async {
        let clock = TestClock()
        let coordinator = RetryCoordinator(eventHub: NetworkEventHub(), clock: clock)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let request = URLRequest(url: URL(string: "https://example.test/retry")!)
        let job = Task {
            try await coordinator.execute(
                retryPolicy: ExponentialBackoffRetryPolicy(
                    maxRetries: 1, retryDelay: 1e308, maxDelay: 1e308, jitterRatio: 0),
                networkMonitor: nil, requestID: UUID(), eventObservers: [],
                operation: { _, _ -> Int in
                    calls.withLock { $0 += 1 }
                    throw RequestExecutionFailure(
                        error: .timeout(reason: .requestTimeout), request: request)
                })
        }
        await withTaskCancellationHandler {
            #expect(await clock.waitForEnqueuedCount(atLeast: 1))
            clock.advance(by: SchedulingTime.maximumSleepSlice)
            #expect(await clock.waitForEnqueuedCount(atLeast: 2))
            #expect(calls.withLock { $0 } == 1)
            job.cancel()
            do {
                _ = try await job.value
                Issue.record("Expected cancellation")
            } catch { #expect(NetworkError.isCancellation(error)) }
            #expect(clock.waiterCount == 0)
        } onCancel: {
            job.cancel()
        }
    }
}

private struct InvalidComputedDelayPolicy: RetryPolicy {
    let delay: Double
    let maxRetries = 1
    let retryDelay = 0.0
    func retryDelay(for retryIndex: Int) -> TimeInterval { delay }
    func shouldRetry(
        error: NetworkError, retryIndex: Int, request: URLRequest?, response: HTTPURLResponse?
    ) -> RetryDecision { .retry }
}
