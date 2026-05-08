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

        let originalError = NetworkError.configuration(reason: .invalidRequest("nope"))
        let failed = RefreshLifecycleReducer.reduce(
            state: inFlight,
            event: .fail(id: id, error: originalError),
            context: context(now: now, cooldown: .exponentialBackoff(base: 5, max: 60))
        ).state

        #expect(failed.consecutiveFailures == 1)
        guard case .cooldown(let until, let lastError) = failed.phase else {
            Issue.record("failure should enter cooldown")
            return
        }
        #expect(until == now.addingTimeInterval(5))
        // The cooldown phase carries the original error untouched so callers
        // can surface the actual transport / decode failure to consumers.
        guard
            let stored = lastError as? NetworkError,
            case .configuration(let reason) = stored,
            case .invalidRequest(let message) = reason
        else {
            Issue.record("expected stored lastError to be NetworkError.configuration(.invalidRequest)")
            return
        }
        #expect(message == "nope")
    }

    @Test("failure with disabled cooldown stays idle but counts the failure")
    func failureWithDisabledCooldownStaysIdle() {
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
            context: context(now: now, cooldown: .disabled)
        ).state

        #expect(failed.consecutiveFailures == 1)
        if case .idle = failed.phase {
            // expected — disabled cooldown collapses straight back to idle
        } else {
            Issue.record("disabled cooldown should leave the reducer in .idle")
        }
    }

    @Test("cancel for the matching id returns to idle and emits no effects")
    func cancelMatchingIdReturnsToIdle() {
        let id = UUID()
        let task = Task<String, Error> { "token" }
        defer { task.cancel() }
        let inFlight = RefreshLifecycleReducer.reduce(
            state: RefreshLifecycleState(phase: .idle, consecutiveFailures: 4),
            event: .start(id: id, task: task),
            context: context()
        ).state

        let cancelled = RefreshLifecycleReducer.reduce(
            state: inFlight,
            event: .cancel(id: id),
            context: context()
        )

        #expect(!cancelled.state.isRefreshInProgress)
        #expect(cancelled.state.consecutiveFailures == 4)
        if case .idle = cancelled.state.phase {
            // expected
        } else {
            Issue.record("cancel should return to idle")
        }
        #expect(cancelled.effects.isEmpty)
    }

    @Test("cancel for a stale id keeps the in-flight phase")
    func cancelStaleIdIsNoOp() {
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
            event: .cancel(id: UUID()),
            context: context()
        )

        #expect(stale.state.isRefreshInProgress)
        #expect(stale.effects == [.ignoreStaleCompletion])
    }

    @Test("stale failure preserves phase and failure count")
    func staleFailureIsNoOp() {
        let id = UUID()
        let task = Task<String, Error> { "token" }
        defer { task.cancel() }
        let inFlight = RefreshLifecycleReducer.reduce(
            state: RefreshLifecycleState(phase: .idle, consecutiveFailures: 2),
            event: .start(id: id, task: task),
            context: context()
        ).state

        let stale = RefreshLifecycleReducer.reduce(
            state: inFlight,
            event: .fail(id: UUID(), error: NetworkError.configuration(reason: .invalidRequest("late"))),
            context: context()
        )

        #expect(stale.state.isRefreshInProgress)
        #expect(stale.state.consecutiveFailures == 2)
        #expect(stale.effects == [.ignoreStaleCompletion])
    }

    @Test("start while non-idle is a no-op")
    func startWhileNonIdleIsNoOp() {
        let id = UUID()
        let task = Task<String, Error> { "token" }
        defer { task.cancel() }
        let inFlight = RefreshLifecycleReducer.reduce(
            state: .initial,
            event: .start(id: id, task: task),
            context: context()
        ).state

        let secondId = UUID()
        let secondTask = Task<String, Error> { "second" }
        defer { secondTask.cancel() }
        let attempted = RefreshLifecycleReducer.reduce(
            state: inFlight,
            event: .start(id: secondId, task: secondTask),
            context: context()
        )

        // The non-idle guard short-circuits without stashing the new task or
        // emitting any effects, so the original in-flight task is preserved.
        guard case .inFlight(let preservedID, _) = attempted.state.phase else {
            Issue.record("non-idle .start should keep the reducer in-flight")
            return
        }
        #expect(preservedID == id)
        #expect(attempted.state.consecutiveFailures == inFlight.consecutiveFailures)
        #expect(attempted.effects.isEmpty)
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
