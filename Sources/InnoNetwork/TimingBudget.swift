import Foundation

/// A relative budget, not an absolute instant. Never convert the whole input
/// to timer units: even a valid Duration may exceed a platform timer's range.
package struct TimingBudget: Sendable {
    private enum Amount: Sendable {
        case duration(Duration)
        case seconds(TimeInterval)
    }

    private let amount: Amount
    private let startedAt: Duration

    package init(duration: Duration, startedAt: Duration) {
        self.amount = .duration(max(.zero, duration))
        self.startedAt = startedAt
    }

    package init(seconds: TimeInterval, startedAt: Duration) throws {
        guard seconds.isFinite else { throw SchedulingTimeFailure.nonFiniteInterval }
        self.amount = .seconds(max(0, seconds))
        self.startedAt = startedAt
    }

    package func sleepSlice(at now: Duration) -> Duration {
        let elapsed = max(.zero, now - startedAt)
        switch amount {
        case .duration(let budget):
            guard elapsed < budget else { return .zero }
            return min(SchedulingTime.maximumSleepSlice, budget - elapsed)
        case .seconds(let budget):
            let elapsedSeconds = elapsed / .seconds(1)
            guard elapsedSeconds < budget else { return .zero }
            return .seconds(min(SchedulingTime.maximumSleepSeconds, budget - elapsedSeconds))
        }
    }

    package func remainingSeconds(at now: Duration) -> TimeInterval {
        let elapsed = max(.zero, now - startedAt)
        switch amount {
        case .duration(let budget):
            return elapsed >= budget ? 0 : (budget - elapsed) / .seconds(1)
        case .seconds(let budget):
            return max(0, budget - elapsed / .seconds(1))
        }
    }

    package func isExpired(at now: Duration) -> Bool {
        sleepSlice(at: now) <= .zero
    }

    package func sleep(using clock: any InnoNetworkClock) async throws {
        try Task.checkCancellation()
        while true {
            let slice = sleepSlice(at: clock.monotonicNow())
            guard slice > .zero else { return }
            try await clock.sleep(for: slice)
            try Task.checkCancellation()
        }
    }
}

package enum SchedulingTimeFailure: Error {
    case nonFiniteInterval
}

package enum SchedulingTime {
    // Internal timer slice, never a cap on the caller's total delay. Both
    // ContinuousClock and SuspendingClock keep their own elapsed-time semantics.
    package static let maximumSleepSeconds: TimeInterval = 86_400
    package static let maximumSleepSlice: Duration = .seconds(86_400)

    package static func sleep<C: Clock>(for seconds: TimeInterval, clock: C) async throws
    where C.Duration == Duration {
        let budget = try TimingBudget(seconds: seconds, startedAt: .zero)
        try await sleep(budget: budget, clock: clock)
    }

    package static func sleep<C: Clock>(for duration: Duration, clock: C) async throws
    where C.Duration == Duration {
        let budget = TimingBudget(duration: duration, startedAt: .zero)
        try await sleep(budget: budget, clock: clock)
    }

    private static func sleep<C: Clock>(budget: TimingBudget, clock: C) async throws
    where C.Duration == Duration {
        let started = clock.now
        try Task.checkCancellation()
        while true {
            let slice = budget.sleepSlice(at: started.duration(to: clock.now))
            guard slice > .zero else { return }
            try await clock.sleep(for: slice)
            try Task.checkCancellation()
        }
    }
}

package extension InnoNetworkClock {
    func sleepSafely(for duration: Duration) async throws {
        try Task.checkCancellation()
        if duration <= SchedulingTime.maximumSleepSlice {
            try await sleep(for: max(.zero, duration))
            try Task.checkCancellation()
        } else {
            try await TimingBudget(duration: duration, startedAt: monotonicNow()).sleep(using: self)
        }
    }

    func sleep(forSeconds seconds: TimeInterval) async throws {
        guard seconds.isFinite else { throw SchedulingTimeFailure.nonFiniteInterval }
        // Preserve one-shot behavior for ordinary waits, including the public
        // caller-controlled sleep closure that need not advance wall-clock now.
        if seconds <= SchedulingTime.maximumSleepSeconds {
            try Task.checkCancellation()
            try await sleep(for: .seconds(max(0, seconds)))
            try Task.checkCancellation()
        } else {
            try await TimingBudget(seconds: seconds, startedAt: monotonicNow()).sleep(using: self)
        }
    }
}
