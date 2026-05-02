import Foundation
import InnoNetwork

package enum DownloadLifecycleEvent: Sendable, Equatable {
    case transition(to: DownloadState)
}

package enum DownloadLifecycleEffect: Sendable, Equatable {
    case rejectIllegalTransition(from: DownloadState, to: DownloadState)
}

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
        }
    }
}
