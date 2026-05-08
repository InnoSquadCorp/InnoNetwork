import Foundation
import Testing

@testable import InnoNetwork

@Suite("Refresh lifecycle reducer")
struct RefreshLifecycleReducerTests {

    @Test("start moves idle state into in-flight")
    func startMovesIdleIntoInFlight() {
        let id = UUID()
        let task = Task<String, Error> { "token" }
        defer { task.cancel() }

        let reduction = RefreshLifecycleReducer.reduce(
            state: .initial,
            event: .start(id: id, task: task),
            context: context()
        )

        #expect(reduction.state.isRefreshInProgress)
    }

    @Test("success resets cooldown failure count")
    func successResetsFailureCount() {
        let id = UUID()
        let task = Task<String, Error> { "token" }
        defer { task.cancel() }
        let inFlight = RefreshLifecycleReducer.reduce(
            state: RefreshLifecycleState(phase: .idle, consecutiveFailures: 2),
            event: .start(id: id, task: task),
            context: context()
        ).state

        let finished = RefreshLifecycleReducer.reduce(
            state: inFlight,
            event: .succeed(id: id),
            context: context()
        ).state

        #expect(!finished.isRefreshInProgress)
        #expect(finished.consecutiveFailures == 0)
        if case .idle = finished.phase {
            // expected
        } else {
            Issue.record("success should return to idle")
        }
    }

    @Test("failure enters cooldown using next failure count")
    func failureEntersCooldown() {
        let id = UUID()
        let task = Task<String, Error> { "token" }
        defer { task.cancel() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let inFlight = RefreshLifecycleReducer.reduce(
            state: .initial,
            event: .start(id: id, task: task),
            context: context(now: now)
        ).state

        let failed = RefreshLifecycleReducer.reduce(
            state: inFlight,
            event: .fail(id: id, error: NetworkError.configuration(reason: .invalidRequest("nope"))),
            context: context(now: now, cooldown: .exponentialBackoff(base: 5, max: 60))
        ).state

        #expect(failed.consecutiveFailures == 1)
        if case .cooldown(let until, _) = failed.phase {
            #expect(until == now.addingTimeInterval(5))
        } else {
            Issue.record("failure should enter cooldown")
        }
    }

    @Test("stale completions keep the current in-flight state")
    func staleCompletionIgnored() {
        let id = UUID()
        let task = Task<String, Error> { "token" }
        defer { task.cancel() }
        let inFlight = RefreshLifecycleReducer.reduce(
            state: .initial,
            event: .start(id: id, task: task),
            context: context()
        ).state

        let stale = RefreshLifecycleReducer.reduce(
            state: inFlight,
            event: .succeed(id: UUID()),
            context: context()
        )

        #expect(stale.state.isRefreshInProgress)
        #expect(stale.effects == [.ignoreStaleCompletion])
    }

    @Test("expired cooldown returns to idle but preserves failure count")
    func expiredCooldownReturnsToIdle() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let state = RefreshLifecycleState(
            phase: .cooldown(
                until: now.addingTimeInterval(-1),
                lastError: NetworkError.configuration(reason: .invalidRequest("cooldown"))
            ),
            consecutiveFailures: 3
        )

        let expired = RefreshLifecycleReducer.reduce(
            state: state,
            event: .expireCooldownIfNeeded,
            context: context(now: now)
        ).state

        #expect(expired.consecutiveFailures == 3)
        if case .idle = expired.phase {
            // expected
        } else {
            Issue.record("expired cooldown should return to idle")
        }
    }

    private func context(
        now: Date = Date(timeIntervalSince1970: 1_700_000_000),
        cooldown: RefreshFailureCooldown = .exponentialBackoff(base: 1, max: 30)
    ) -> RefreshLifecycleContext {
        RefreshLifecycleContext(now: now, failureCooldown: cooldown)
    }
}
