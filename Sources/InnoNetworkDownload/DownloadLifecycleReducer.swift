import Foundation
import InnoNetwork

/// Events the download lifecycle reducer accepts.
///
/// `transition(to:)` is the historical case that drives ``DownloadState``
/// validation against ``DownloadState/canTransition(to:)``. `startAttempt`
/// is the 4.0.0 epoch-tracking case: callers issue it whenever a download
/// retry begins so the reducer can emit an ``DownloadLifecycleEffect/advancedEpoch``
/// effect that the surrounding actor uses to discard stale callbacks from
/// the previous attempt. The state passed in is preserved on this path —
/// the reducer treats epoch advancement as orthogonal to the transition
/// table.
package enum DownloadLifecycleEvent: Sendable, Equatable {
    case transition(to: DownloadState)
    case startAttempt(generation: Int, attempt: Int)
}

/// Side effects the download reducer asks its caller to perform.
///
/// `rejectIllegalTransition` carries the original `(from, to)` pair so a
/// log line or assertion can pin which transition was attempted.
/// `advancedEpoch` is paired with the new `startAttempt` event and tells
/// the surrounding actor to record the new `(generation, attempt)` pair —
/// the WebSocket lifecycle uses the same shape to break ties between
/// in-flight callbacks belonging to different reconnect cycles. The
/// download equivalent uses it for retry cycles.
package enum DownloadLifecycleEffect: Sendable, Equatable {
    case rejectIllegalTransition(from: DownloadState, to: DownloadState)
    case advancedEpoch(generation: Int, attempt: Int)
}

/// Pure state-transition function for the download lifecycle.
///
/// Two responsibilities:
/// 1. Enforce ``DownloadState/canTransition(to:)`` for `.transition` events.
/// 2. Forward `.startAttempt` events as ``DownloadLifecycleEffect/advancedEpoch``
///    side effects without mutating the visible state, so the caller's
///    own bookkeeping stays in sync with the reducer's view of the
///    current attempt.
///
/// The reducer is value-pure: the same `(state, event)` pair always
/// produces the same reduction. Persisting the new epoch values (or
/// rejecting illegal transitions) is the caller's job.
package enum DownloadLifecycleReducer: StateReducer {
    package static func reduce(
        state: DownloadState,
        event: DownloadLifecycleEvent,
        context: Void = ()
    ) -> StateReduction<DownloadState, DownloadLifecycleEffect> {
        _ = context
        switch event {
        case .transition(let next):
            guard state.canTransition(to: next) else {
                return StateReduction(
                    state: state,
                    effects: [.rejectIllegalTransition(from: state, to: next)]
                )
            }
            return StateReduction(state: next)
        case .startAttempt(let generation, let attempt):
            // Epoch advancement does not move through the transition table:
            // a retry can begin from `.failed`, `.paused`, or even mid-
            // `.downloading` after a transport blip, and forcing those
            // through `canTransition` would either reject legitimate
            // restarts or require widening the table to cover every
            // legal pre-attempt state. The caller already validates the
            // surrounding state via separate `.transition` events; this
            // case only records the new generation/attempt for callback
            // disambiguation.
            return StateReduction(
                state: state,
                effects: [.advancedEpoch(generation: generation, attempt: attempt)]
            )
        }
    }
}
