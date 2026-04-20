import Foundation
import os
import InnoNetwork


/// Virtual-time clock used by deterministic timing tests across all three
/// test targets. Production code receives an `any InnoNetworkClock`;
/// production paths use `SystemClock`, and tests inject this implementation
/// to drive timing deterministically via `advance(by:)` instead of
/// wall-clock sleeps.
///
/// Implementation notes:
/// - State is held behind an `OSAllocatedUnfairLock` so that enqueue,
///   cancellation, and `advance` all serialise synchronously. This avoids the
///   race where `withTaskCancellationHandler.onCancel` schedules async cleanup
///   that has not yet landed when the test calls `advance` — that race would
///   let a cancelled waiter wake up with success and let the `try await
///   clock.sleep(for:)` call return normally after its enclosing task was
///   cancelled.
/// - `sleep(for:)` also performs `Task.checkCancellation()` after resuming so
///   a waiter that was fired in a tight race with cancellation still surfaces
///   as `CancellationError` to the caller.
package final class TestClock: InnoNetworkClock, @unchecked Sendable {

    private struct Waiter {
        let id: UUID
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var virtualNow: Duration = .zero
        var waiters: [Waiter] = []
        /// Monotone counter of every `sleep(for:)` call that actually enqueued
        /// a waiter (i.e. duration > 0 and task not yet cancelled). Tests use
        /// snapshots of this counter to detect when the coordinator has
        /// registered a fresh sleep after a cycle completes — more reliable
        /// than `waiterCount`, which transiently dips to zero between waiters.
        var enqueuedCount: Int = 0
    }

    private let stateLock = OSAllocatedUnfairLock<State>(initialState: State())

    package init() {}

    package func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enum Action { case resume, cancel, wait }
                let action: Action = stateLock.withLock { state in
                    if Task.isCancelled { return .cancel }
                    if duration <= .zero { return .resume }
                    let deadline = state.virtualNow + duration
                    state.waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation))
                    state.enqueuedCount += 1
                    return .wait
                }
                switch action {
                case .resume:
                    continuation.resume()
                case .cancel:
                    continuation.resume(throwing: CancellationError())
                case .wait:
                    break
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            let waiter: Waiter? = stateLock.withLock { state in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Advances virtual time and resumes every waiter whose deadline has now
    /// elapsed, in deadline order.
    package func advance(by duration: Duration) {
        let ready: [Waiter] = stateLock.withLock { state in
            state.virtualNow += duration
            let fired = state.waiters.filter { $0.deadline <= state.virtualNow }
            state.waiters.removeAll { $0.deadline <= state.virtualNow }
            return fired.sorted(by: { $0.deadline < $1.deadline })
        }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    /// Outstanding waiter count. Useful for gating `advance` on the coordinator
    /// having actually registered its sleep.
    package var waiterCount: Int {
        stateLock.withLock { $0.waiters.count }
    }

    /// Monotone counter of total sleeps enqueued since the clock was created.
    /// Strictly increases; tests snapshot it before advancing a cycle and wait
    /// for it to reach a target before proceeding.
    package var enqueuedCount: Int {
        stateLock.withLock { $0.enqueuedCount }
    }

    /// Awaits until `enqueuedCount` reaches at least `target` or the timeout
    /// elapses. Returns `true` if the target was reached.
    package func waitForEnqueuedCount(atLeast target: Int, timeout: TimeInterval = 1.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while stateLock.withLock({ $0.enqueuedCount }) < target {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    /// Awaits until at least `count` waiters are registered or `timeout`
    /// elapses. Returns `true` if the target was reached.
    package func waitForWaiters(count: Int, timeout: TimeInterval = 1.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while stateLock.withLock({ $0.waiters.count }) < count {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }
}
