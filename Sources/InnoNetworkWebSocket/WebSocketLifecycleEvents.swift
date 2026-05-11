import Foundation
import InnoNetwork

// Split out of `WebSocketLifecycleReducer.swift` so the reducer's input
// and output value types — `WebSocketLifecycleEvent`,
// `WebSocketLifecycleDecisionContext`, `WebSocketLifecycleEffect`,
// `WebSocketLifecycleTransition`, and `WebSocketStateTransitionResult`
// — live alongside the state model. All types stay `package`; this
// file only relocates code, no behaviour changes.

package enum WebSocketLifecycleEvent: Sendable, Equatable {
    case connect
    case didOpen(generation: Int, protocolName: String?)
    case manualDisconnect(closeCode: WebSocketCloseCode, error: WebSocketError?)
    case didClose(
        generation: Int,
        closeCode: WebSocketCloseCode,
        disposition: WebSocketCloseDisposition,
        error: WebSocketError?
    )
    case failure(generation: Int?, disposition: WebSocketCloseDisposition, error: WebSocketError)
    case closeTimeout(closeCode: WebSocketCloseCode, error: WebSocketError)
    case reconnectTimerFired
    case reset
}

package struct WebSocketLifecycleDecisionContext: Sendable, Equatable {
    package let reconnectAction: WebSocketReconnectAction?
    package let attempt: Int?

    package init(
        reconnectAction: WebSocketReconnectAction? = nil,
        attempt: Int? = nil
    ) {
        self.reconnectAction = reconnectAction
        self.attempt = attempt
    }
}

package enum WebSocketLifecycleEffect: Sendable, Equatable {
    case startConnection(generation: Int)
    case startHeartbeat
    case cancelHeartbeat
    case cancelReconnect
    case cancelMessageListener
    case cleanupRuntime
    case scheduleCloseTimeout(closeCode: WebSocketCloseCode)
    case cancelCloseTimeout
    case publishConnected(protocolName: String?)
    case publishDisconnected(error: WebSocketError?)
    case publishError(WebSocketError)
    case scheduleReconnect
    case finishTerminal(generation: Int)
    case ignoreStaleCallback
}

package struct WebSocketLifecycleTransition: Sendable, Equatable {
    package let state: WebSocketLifecycleState
    package let effects: [WebSocketLifecycleEffect]

    package var isIgnoredCallback: Bool {
        effects == [.ignoreStaleCallback]
    }

    package init(
        state: WebSocketLifecycleState,
        effects: [WebSocketLifecycleEffect]
    ) {
        self.state = state
        self.effects = effects
    }
}

package enum WebSocketStateTransitionResult: Sendable, Equatable {
    case applied(previous: WebSocketState, next: WebSocketState)
    case rejected(previous: WebSocketState, next: WebSocketState)

    package var wasApplied: Bool {
        switch self {
        case .applied:
            true
        case .rejected:
            false
        }
    }
}
