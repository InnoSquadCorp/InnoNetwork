import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

@Suite("Bounded scheduling preserves relative budgets")
struct TimingBudgetTests {
    @Test(arguments: [Double(Int64.max), Double(Int64.max).nextDown, 1e308])
    func largeSecondsAreNotTimerUnits(seconds: Double) throws {
        let budget = try TimingBudget(seconds: seconds, startedAt: .seconds(5))
        #expect(budget.sleepSlice(at: .seconds(5)) == SchedulingTime.maximumSleepSlice)
        #expect(!budget.isExpired(at: .seconds(5) + SchedulingTime.maximumSleepSlice))
        #expect(budget.remainingSeconds(at: .seconds(5)) == seconds)
    }

    @Test func largeDurationDoesNotReadComponents() {
        let enormous = Duration.seconds(Int64.max) * 2
        let budget = TimingBudget(duration: enormous, startedAt: .seconds(5))
        #expect(budget.sleepSlice(at: .seconds(5)) == SchedulingTime.maximumSleepSlice)
        #expect(!budget.isExpired(at: .seconds(5) + SchedulingTime.maximumSleepSlice))
        #expect(budget.remainingSeconds(at: .seconds(5)) > Double(Int64.max))
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func invalidSecondsFailBeforeScheduling(seconds: Double) {
        #expect(throws: SchedulingTimeFailure.self) {
            try TimingBudget(seconds: seconds, startedAt: .zero)
        }
    }

    @Test func immediateAndBoundarySemantics() throws {
        for seconds in [0.0, -1.0] {
            #expect(try TimingBudget(seconds: seconds, startedAt: .zero).isExpired(at: .zero))
        }
        let budget = TimingBudget(duration: .seconds(2), startedAt: .seconds(5))
        #expect(budget.sleepSlice(at: .seconds(4)) == .seconds(2))
        #expect(budget.sleepSlice(at: .seconds(6)) == .seconds(1))
        #expect(budget.isExpired(at: .seconds(7)))
        #expect(budget.isExpired(at: .seconds(8)))
    }

    @Test(.timeLimit(.minutes(1))) func multipleSlicesUseActualElapsedTime() async throws {
        let clock = TestClock()
        let total = SchedulingTime.maximumSleepSlice + .seconds(2)
        let task = Task { try await clock.sleepSafely(for: total) }
        await withTaskCancellationHandler {
            let first = await clock.waitForEnqueuedCount(atLeast: 1)
            #expect(first)
            guard first else {
                task.cancel()
                _ = await task.result
                return
            }
            clock.advance(by: SchedulingTime.maximumSleepSlice + .seconds(1))
            let second = await clock.waitForEnqueuedCount(atLeast: 2)
            #expect(second)
            guard second else {
                task.cancel()
                _ = await task.result
                return
            }
            #expect(clock.waiterCount == 1)
            clock.advance(by: .seconds(1))
            do { try await task.value } catch { Issue.record(error) }
            #expect(clock.waiterCount == 0)
        } onCancel: {
            task.cancel()
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [Double(Int64.max), 1e308])
    func hugeSecondsRemainPendingAndCancel(seconds: Double) async throws {
        let clock = TestClock()
        let task = Task { try await clock.sleep(forSeconds: seconds) }
        await withTaskCancellationHandler {
            let first = await clock.waitForEnqueuedCount(atLeast: 1)
            #expect(first)
            guard first else {
                task.cancel()
                _ = await task.result
                return
            }
            clock.advance(by: SchedulingTime.maximumSleepSlice)
            #expect(await clock.waitForEnqueuedCount(atLeast: 2))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(clock.waiterCount == 0)
        } onCancel: {
            task.cancel()
        }
    }

    @Test(.timeLimit(.minutes(1))) func realClockLargeWaitsCancelWithoutFatalConversion() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await SystemClock().sleep(for: .seconds(Int64.max)) }
            group.addTask { try await Task.sleep(for: .milliseconds(5)) }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    @Test(.timeLimit(.minutes(1))) func bothNativeBackendsSupportLargeSeconds() async throws {
        for suspending in [false, true] {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    if suspending {
                        try await SchedulingTime.sleep(for: 1e308, clock: SuspendingClock())
                    } else {
                        try await SchedulingTime.sleep(for: 1e308, clock: ContinuousClock())
                    }
                }
                group.addTask { try await Task.sleep(for: .milliseconds(5)) }
                _ = try await group.next()
                group.cancelAll()
            }
        }
        try await SystemClock().sleep(for: .milliseconds(1))
    }
}
