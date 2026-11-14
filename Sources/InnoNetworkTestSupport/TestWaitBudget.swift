import Foundation

/// Upper bounds for "wait until this happens" helpers in the repository's own
/// test targets.
///
/// Swift Testing starts every test of a `swift test --parallel` run inside one
/// process, so the first seconds of a full run queue thousands of tasks behind
/// a cooperative pool that has one thread per core. A wait that polls for an
/// event therefore cannot treat a short wall-clock timeout as proof that the
/// event will never arrive: the timeout may expire while the code under test is
/// still waiting for a thread. Positive waits pass their nominal timeout
/// through ``upperBound(_:)-(TimeInterval)`` so the budget is generous under
/// load and unchanged in cost when the event arrives promptly.
///
/// The bound is a hang guard, not a latency contract. Every wait that uses it
/// returns as soon as its condition holds, so a passing run pays nothing for
/// the larger bound; only a failing wait takes longer to report, and never
/// more than thirty seconds. For the same reason the bound must never appear
/// in an assertion about how long something took — test timing contracts with
/// ``TestClock`` instead, where time advances only when the test says so.
///
/// Do not use this for negative assertions ("nothing happens during this
/// window"): a longer window only makes those tests slower. Wrap them in
/// ``observingAbsence(_:)``, or better, wait on a deterministic barrier.
/// Set `INNONETWORK_TEST_WAIT_SCALE=1` to fail fast while debugging.
package enum TestWaitBudget {
    /// Multiplier applied to nominal timeouts. Override with the
    /// `INNONETWORK_TEST_WAIT_SCALE` environment variable, for example `1` to
    /// fail fast while debugging a single test.
    package static let scale: Double = {
        guard
            let raw = ProcessInfo.processInfo.environment["INNONETWORK_TEST_WAIT_SCALE"],
            let value = Double(raw),
            value.isFinite,
            value >= 1
        else {
            return defaultScale
        }
        return value
    }()

    private static let defaultScale: Double = 20
    private static let scaledCeiling: TimeInterval = 30

    /// `true` while ``observingAbsence(_:)`` runs. Wait helpers called inside
    /// it keep their nominal timeout.
    @TaskLocal private static var isObservingAbsence = false

    /// Runs `body` with wait helpers pinned to their nominal timeouts.
    ///
    /// Wrap a wait whose expected outcome is the timeout itself — "this event
    /// must not arrive during the window" — so the window is not stretched.
    /// A stretched window would only slow the passing case, and can let an
    /// unrelated timer (a close-handshake deadline, a heartbeat) fire inside
    /// the window and change the state the test asserts afterwards.
    package static func observingAbsence<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await $isObservingAbsence.withValue(true) {
            try await body()
        }
    }

    /// Returns the scaled upper bound for a positive wait.
    ///
    /// The result is never shorter than `nominal`, and scaling alone never
    /// pushes it past thirty seconds so a genuinely missing event still fails
    /// in bounded time.
    package static func upperBound(_ nominal: TimeInterval) -> TimeInterval {
        guard nominal.isFinite, nominal > 0, !isObservingAbsence else { return nominal }
        let scaled = min(nominal * scale, max(nominal, scaledCeiling))
        return max(nominal, scaled)
    }

    /// `Duration` overload of ``upperBound(_:)-(TimeInterval)``.
    package static func upperBound(_ nominal: Duration) -> Duration {
        let components = nominal.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return .seconds(upperBound(seconds))
    }
}
