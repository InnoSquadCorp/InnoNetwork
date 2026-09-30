import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

@APIDefinition(method: .get, path: "/large-timing", auth: .anonymous)
private struct LargeTimingEndpoint { typealias APIResponse = String }

@Suite("Large timing policy budgets", .timeLimit(.minutes(1)))
struct LargeTimingPolicyTests {
    @Test func operationDeadlineDoesNotExpireAfterOneSlice() async throws {
        let deadlineClock = TestClock()
        let baseClock = TestClock()
        let base = StubNetworkClient(clock: baseClock)
        base.register("late", for: LargeTimingEndpoint(), behavior: .delayed(seconds: 60))
        let operation = OperationNetworkClient(client: base, deadlineClock: deadlineClock).start(
            LargeTimingEndpoint(), deadline: .init(after: .seconds(Int64.max)))
        await withTaskCancellationHandler {
            #expect(await baseClock.waitForEnqueuedCount(atLeast: 1))
            #expect(await deadlineClock.waitForEnqueuedCount(atLeast: 1))
            deadlineClock.advance(by: SchedulingTime.maximumSleepSlice)
            #expect(await deadlineClock.waitForEnqueuedCount(atLeast: 2))
            operation.cancel()
            do {
                _ = try await operation.value()
                Issue.record("Expected cancellation")
            } catch let failure as NetworkFailure {
                #expect(failure.kind == .cancelled)
            } catch { Issue.record(error) }
            #expect(deadlineClock.waiterCount == 0)
            #expect(baseClock.waiterCount == 0)
        } onCancel: {
            operation.cancel()
        }
    }

    @Test func hugeQueueWaitRemainsPendingAndReleasesCleanly() async throws {
        let clock = TestClock()
        let coordinator = RequestAdmissionCoordinator(
            policy: .init(
                maximumConcurrentRequests: 1, maximumPendingRequests: 1,
                maximumQueueWait: .seconds(Int64.max)), clock: clock)
        let request = URLRequest(url: try #require(URL(string: "https://example.test/a")))
        let first = try await coordinator.acquire(for: request)
        let waiting = Task { try await coordinator.acquire(for: request) }
        await cancelAfterOneSlice(waiting, clock: clock)
        await coordinator.release(scope: first.scope)
        let state = await coordinator.snapshot
        #expect(state.active == 0 && state.pending == 0 && state.scopes == 0)
    }

    @Test(arguments: [
        AdvancedRateLimitAlgorithm.tokenBucket(capacity: Double(Int64.max), refillPerSecond: 1),
        .tokenBucket(capacity: Double(Int64.max).nextDown, refillPerSecond: 1),
        .slidingWindow(limit: 1, interval: .seconds(Int64.max)),
    ])
    func hugeQuotasDoNotAdmitAfterOneSlice(algorithm: AdvancedRateLimitAlgorithm) async throws {
        let clock = TestClock()
        let cost: Double
        switch algorithm {
        case .tokenBucket(let capacity, _): cost = capacity
        case .slidingWindow: cost = 1
        }
        let coordinator = AdvancedRateLimitCoordinator(
            policy: .init(algorithm: algorithm, defaultRequestCost: cost), clock: clock)
        let request = URLRequest(url: try #require(URL(string: "https://example.test/a")))
        let first = try await coordinator.reserve(for: request)
        #expect(await coordinator.commit(first) == nil)
        await coordinator.finish(first)
        let waiting = Task { try await coordinator.reserve(for: request) }
        await cancelAfterOneSlice(waiting, clock: clock)
        #expect(await coordinator.snapshot.pending == 0)
    }

    @Test func dispatchQuotaAlsoReturnsBoundedSlices() async throws {
        let clock = TestClock()
        let coordinator = AdvancedRateLimitCoordinator(
            policy: .init(
                algorithm: .tokenBucket(capacity: 2, refillPerSecond: 1),
                serverFeedback: .retryAfter(maximumDelay: Double(Int64.max))), clock: clock)
        let request = URLRequest(url: try #require(URL(string: "https://example.test/a")))
        let first = try await coordinator.reserve(for: request)
        let second = try await coordinator.reserve(for: request)
        #expect(await coordinator.commit(first) == nil)
        let response = try #require(
            HTTPURLResponse(
                url: request.url!, statusCode: 503, httpVersion: nil,
                headerFields: ["Retry-After": String(Int64.max)]))
        await coordinator.observe(response: response, for: request, reservation: first)
        #expect(await coordinator.commit(second) == SchedulingTime.maximumSleepSlice)
        clock.advance(by: SchedulingTime.maximumSleepSlice)
        #expect(await coordinator.commit(second) == SchedulingTime.maximumSleepSlice)
        await coordinator.refund(second)
        #expect(await coordinator.snapshot.pending == 0)
    }

    @Test func hugeServerCooldownCannotBeShortenedToTimerSlice() async throws {
        let clock = TestClock()
        let coordinator = AdvancedRateLimitCoordinator(
            policy: .init(
                algorithm: .tokenBucket(capacity: 2, refillPerSecond: 1),
                serverFeedback: .retryAfter(maximumDelay: Double(Int64.max))), clock: clock)
        let url = try #require(URL(string: "https://example.test/a"))
        let request = URLRequest(url: url)
        let first = try await coordinator.reserve(for: request)
        _ = await coordinator.commit(first)
        let response = try #require(
            HTTPURLResponse(
                url: url, statusCode: 503, httpVersion: nil,
                headerFields: ["Retry-After": String(Int64.max)]))
        await coordinator.observe(response: response, for: request, reservation: first)
        let waiting = Task { try await coordinator.reserve(for: request) }
        await cancelAfterOneSlice(waiting, clock: clock)
        #expect(await coordinator.snapshot.pending == 0)
    }

    @Test func hugeFixedWindowCannotAdmitAfterOneSlice() async throws {
        let clock = TestClock()
        let limiter = FixedWindowRequestLimiter(maximumRequests: 1, interval: .seconds(Int64.max), clock: clock)
        try await limiter.acquire()
        let waiting = Task { try await limiter.acquire() }
        await cancelAfterOneSlice(waiting, clock: clock)
    }

    private func cancelAfterOneSlice<Value: Sendable>(_ task: Task<Value, Error>, clock: TestClock) async {
        await withTaskCancellationHandler {
            let first = await clock.waitForEnqueuedCount(atLeast: 1)
            #expect(first)
            if first {
                clock.advance(by: SchedulingTime.maximumSleepSlice)
                #expect(await clock.waitForEnqueuedCount(atLeast: 2))
                #expect(clock.waiterCount == 1)
            }
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            #expect(clock.waiterCount == 0)
        } onCancel: {
            task.cancel()
        }
    }
}
