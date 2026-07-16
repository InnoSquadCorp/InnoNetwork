import Foundation
import os

/// Linearizes synchronous URLSession completion staging with destructive
/// manager lifecycle operations for one logical task id.
///
/// Foundation owns the temporary download URL only for the delegate callback,
/// so staging cannot hop to an actor. This lock-backed gate lets the delegate
/// claim that synchronous interval while async cancel/shutdown callers wait via
/// continuations instead of blocking a cooperative executor thread.
package final class DownloadCompletionAdmissionGate: Sendable {
    private struct AttemptKey: Hashable, Sendable {
        let taskID: String
        let taskIdentifier: Int?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.taskID == rhs.taskID && lhs.taskIdentifier == rhs.taskIdentifier
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(taskID)
            hasher.combine(taskIdentifier)
        }
    }

    private enum Phase: Sendable {
        case open
        case staging
        case closed
    }

    private struct State: Sendable {
        var phases: [AttemptKey: Phase] = [:]
        var journaledTaskIDs = Set<String>()
        /// Once a destructive lifecycle wins, previously unknown attempts for
        /// that logical id remain closed. A newly-created retry/resume attempt
        /// must be opened explicitly by its concrete URLSession identifier, so
        /// a late callback from the retired attempt cannot become authoritative
        /// merely because the logical task id was reused.
        var closesUnknownAttemptsForTaskIDs = Set<String>()
        var destructiveWaiters: [String: [CheckedContinuation<Bool, Never>]] = [:]
        var observationWaiters: [String: [CheckedContinuation<Bool, Never>]] = [:]
    }

    private enum ClaimAction {
        case resume(Bool)
        case wait
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package init() {}

    /// Opens one concrete URLSession attempt. This is the only operation that
    /// can admit a new attempt after a pause/cancel/retry has closed the prior
    /// generation for the same logical task id.
    package func openAttempt(taskID: String, taskIdentifier: Int) {
        guard !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        state.withLock { state in
            guard !state.journaledTaskIDs.contains(taskID) else { return }
            state.phases[
                AttemptKey(taskID: taskID, taskIdentifier: taskIdentifier)
            ] = .open
        }
    }

    /// Claims the delegate's synchronous ownership-transfer interval.
    package func beginStaging(
        taskID: String,
        taskIdentifier: Int? = nil
    ) -> Bool {
        guard !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return state.withLock { state in
            guard !state.journaledTaskIDs.contains(taskID) else { return false }
            let key = AttemptKey(taskID: taskID, taskIdentifier: taskIdentifier)
            let phase = state.phases[key]
            if state.closesUnknownAttemptsForTaskIDs.contains(taskID), phase != .open {
                return false
            }
            guard phase == nil || phase == .open else { return false }
            state.phases[key] = .staging
            return true
        }
    }

    /// Completes synchronous staging and releases lifecycle waiters. `true`
    /// means the deterministic journal now owns the payload.
    package func finishStaging(
        taskID: String,
        taskIdentifier: Int? = nil,
        journaled: Bool
    ) {
        let result = state.withLock {
            state -> (
                [CheckedContinuation<Bool, Never>],
                [CheckedContinuation<Bool, Never>],
                Bool
            ) in
            let key = AttemptKey(taskID: taskID, taskIdentifier: taskIdentifier)
            guard case .some(.staging) = state.phases[key] else {
                return ([], [], state.journaledTaskIDs.contains(taskID))
            }
            state.phases[key] = .closed
            if journaled {
                state.journaledTaskIDs.insert(taskID)
            }
            guard !Self.hasStagingAttempt(taskID: taskID, state: state) else {
                return ([], [], state.journaledTaskIDs.contains(taskID))
            }
            let destructiveWaiters = state.destructiveWaiters.removeValue(forKey: taskID) ?? []
            let hasJournal = state.journaledTaskIDs.contains(taskID)
            return (
                destructiveWaiters,
                state.observationWaiters.removeValue(forKey: taskID) ?? [],
                hasJournal
            )
        }
        for waiter in result.0 {
            waiter.resume(returning: !result.2)
        }
        for waiter in result.1 {
            waiter.resume(returning: result.2)
        }
    }

    /// Waits for any in-progress delegate stage, then atomically closes future
    /// completion admission. Returns `false` when an existing journal won.
    package func claimDestructiveLifecycle(taskID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let action = state.withLock { state -> ClaimAction in
                state.closesUnknownAttemptsForTaskIDs.insert(taskID)
                for key in state.phases.keys where key.taskID == taskID {
                    if state.phases[key] == .open {
                        state.phases[key] = .closed
                    }
                }
                if state.journaledTaskIDs.contains(taskID) {
                    return .resume(false)
                }
                if Self.hasStagingAttempt(taskID: taskID, state: state) {
                    state.destructiveWaiters[taskID, default: []].append(continuation)
                    return .wait
                }
                return .resume(true)
            }
            if case .resume(let admitted) = action {
                continuation.resume(returning: admitted)
            }
        }
    }

    /// Observes whether synchronous staging established a journal without
    /// closing admission for a future retry attempt.
    package func hasJournalAfterStaging(taskID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let action = state.withLock { state -> ClaimAction in
                if state.journaledTaskIDs.contains(taskID) {
                    return .resume(true)
                }
                if Self.hasStagingAttempt(taskID: taskID, state: state) {
                    state.observationWaiters[taskID, default: []].append(continuation)
                    return .wait
                }
                return .resume(false)
            }
            if case .resume(let hasJournal) = action {
                continuation.resume(returning: hasJournal)
            }
        }
    }

    /// Registers journal evidence discovered from disk rather than the current
    /// process's delegate callback.
    package func registerJournal(taskID: String) {
        let waiters = state.withLock {
            state -> ([CheckedContinuation<Bool, Never>], [CheckedContinuation<Bool, Never>]) in
            state.journaledTaskIDs.insert(taskID)
            for key in state.phases.keys where key.taskID == taskID {
                if state.phases[key] != .staging {
                    state.phases[key] = .closed
                }
            }
            guard !Self.hasStagingAttempt(taskID: taskID, state: state) else {
                return ([], [])
            }
            return (
                state.destructiveWaiters.removeValue(forKey: taskID) ?? [],
                state.observationWaiters.removeValue(forKey: taskID) ?? []
            )
        }
        for waiter in waiters.0 {
            waiter.resume(returning: false)
        }
        for waiter in waiters.1 {
            waiter.resume(returning: true)
        }
    }

    /// Removes completed/discarded journal ownership. Previously retired
    /// attempts remain closed; a later retry/resume is admitted only after
    /// ``openAttempt(taskID:taskIdentifier:)`` registers its concrete attempt.
    package func release(taskID: String) {
        let waiters = state.withLock {
            state -> ([CheckedContinuation<Bool, Never>], [CheckedContinuation<Bool, Never>]) in
            state.journaledTaskIDs.remove(taskID)
            guard !Self.hasStagingAttempt(taskID: taskID, state: state) else {
                return ([], [])
            }
            return (
                state.destructiveWaiters.removeValue(forKey: taskID) ?? [],
                state.observationWaiters.removeValue(forKey: taskID) ?? []
            )
        }
        for waiter in waiters.0 {
            waiter.resume(returning: true)
        }
        for waiter in waiters.1 {
            waiter.resume(returning: false)
        }
    }

    private static func hasStagingAttempt(taskID: String, state: State) -> Bool {
        state.phases.contains { key, phase in
            key.taskID == taskID && phase == .staging
        }
    }
}
