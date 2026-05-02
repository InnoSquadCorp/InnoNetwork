import Foundation
import InnoNetwork

package struct WebSocketManualDisconnect: Sendable, Equatable {
    package let closeCode: WebSocketCloseCode
    package let error: WebSocketError?

    package init(closeCode: WebSocketCloseCode, error: WebSocketError?) {
        self.closeCode = closeCode
        self.error = error
    }
}

package enum WebSocketLifecycleState: Sendable, Equatable {
    case idle(generation: Int, attempt: Int, autoReconnect: Bool)
    case connecting(generation: Int, attempt: Int, autoReconnect: Bool)
    case connected(generation: Int, attempt: Int, autoReconnect: Bool)
    case disconnecting(generation: Int, attempt: Int, manualDisconnect: WebSocketManualDisconnect)
    case disconnected(
        generation: Int,
        attempt: Int,
        autoReconnect: Bool,
        closeCode: WebSocketCloseCode?,
        disposition: WebSocketCloseDisposition?,
        error: WebSocketError?
    )
    case reconnecting(
        generation: Int,
        attempt: Int,
        autoReconnect: Bool,
        closeCode: WebSocketCloseCode?,
        disposition: WebSocketCloseDisposition?,
        error: WebSocketError?
    )
    case failed(
        generation: Int,
        attempt: Int,
        autoReconnect: Bool,
        closeCode: WebSocketCloseCode?,
        disposition: WebSocketCloseDisposition?,
        error: WebSocketError?
    )

    package static let initial: Self = .idle(generation: 0, attempt: 0, autoReconnect: true)

    package var publicState: WebSocketState {
        switch self {
        case .idle:
            .idle
        case .connecting:
            .connecting
        case .connected:
            .connected
        case .disconnecting:
            .disconnecting
        case .disconnected:
            .disconnected
        case .reconnecting:
            .reconnecting
        case .failed:
            .failed
        }
    }

    package var generation: Int {
        switch self {
        case .idle(let generation, _, _),
            .connecting(let generation, _, _),
            .connected(let generation, _, _),
            .disconnecting(let generation, _, _),
            .disconnected(let generation, _, _, _, _, _),
            .reconnecting(let generation, _, _, _, _, _),
            .failed(let generation, _, _, _, _, _):
            generation
        }
    }

    package var attempt: Int {
        switch self {
        case .idle(_, let attempt, _),
            .connecting(_, let attempt, _),
            .connected(_, let attempt, _),
            .disconnecting(_, let attempt, _),
            .disconnected(_, let attempt, _, _, _, _),
            .reconnecting(_, let attempt, _, _, _, _),
            .failed(_, let attempt, _, _, _, _):
            attempt
        }
    }

    package var autoReconnectEnabled: Bool {
        switch self {
        case .idle(_, _, let autoReconnect),
            .connecting(_, _, let autoReconnect),
            .connected(_, _, let autoReconnect),
            .disconnected(_, _, let autoReconnect, _, _, _),
            .reconnecting(_, _, let autoReconnect, _, _, _),
            .failed(_, _, let autoReconnect, _, _, _):
            autoReconnect
        case .disconnecting:
            false
        }
    }

    package var manualDisconnect: WebSocketManualDisconnect? {
        if case .disconnecting(_, _, let manualDisconnect) = self {
            return manualDisconnect
        }
        return nil
    }

    package var awaitingCloseHandshake: Bool {
        manualDisconnect != nil
    }

    package var closeCode: WebSocketCloseCode? {
        switch self {
        case .disconnected(_, _, _, let closeCode, _, _):
            closeCode
        case .reconnecting(_, _, _, let closeCode, _, _),
            .failed(_, _, _, let closeCode, _, _):
            closeCode
        case .disconnecting(_, _, let manualDisconnect):
            manualDisconnect.closeCode
        case .idle, .connecting, .connected:
            nil
        }
    }

    package var closeDisposition: WebSocketCloseDisposition? {
        switch self {
        case .disconnected(_, _, _, _, let disposition, _),
            .reconnecting(_, _, _, _, let disposition, _),
            .failed(_, _, _, _, let disposition, _):
            disposition
        case .idle, .connecting, .connected, .disconnecting:
            nil
        }
    }

    package var error: WebSocketError? {
        switch self {
        case .disconnected(_, _, _, _, _, let error),
            .reconnecting(_, _, _, _, _, let error),
            .failed(_, _, _, _, _, let error):
            error
        case .disconnecting(_, _, let manualDisconnect):
            manualDisconnect.error
        case .idle, .connecting, .connected:
            nil
        }
    }

    package func withAttempt(_ nextAttempt: Int) -> Self {
        switch self {
        case .idle(let generation, _, let autoReconnect):
            return .idle(generation: generation, attempt: nextAttempt, autoReconnect: autoReconnect)
        case .connecting(let generation, _, let autoReconnect):
            return .connecting(generation: generation, attempt: nextAttempt, autoReconnect: autoReconnect)
        case .connected(let generation, _, let autoReconnect):
            return .connected(generation: generation, attempt: nextAttempt, autoReconnect: autoReconnect)
        case .disconnecting(let generation, _, let manualDisconnect):
            return .disconnecting(generation: generation, attempt: nextAttempt, manualDisconnect: manualDisconnect)
        case .disconnected(let generation, _, let autoReconnect, let closeCode, let disposition, let error):
            return .disconnected(
                generation: generation,
                attempt: nextAttempt,
                autoReconnect: autoReconnect,
                closeCode: closeCode,
                disposition: disposition,
                error: error
            )
        case .reconnecting(let generation, _, let autoReconnect, let closeCode, let disposition, let error):
            return .reconnecting(
                generation: generation,
                attempt: nextAttempt,
                autoReconnect: autoReconnect,
                closeCode: closeCode,
                disposition: disposition,
                error: error
            )
        case .failed(let generation, _, let autoReconnect, let closeCode, let disposition, let error):
            return .failed(
                generation: generation,
                attempt: nextAttempt,
                autoReconnect: autoReconnect,
                closeCode: closeCode,
                disposition: disposition,
                error: error
            )
        }
    }

    package func replacingGeneration(_ nextGeneration: Int) -> Self {
        switch self {
        case .idle(_, let attempt, let autoReconnect):
            return .idle(generation: nextGeneration, attempt: attempt, autoReconnect: autoReconnect)
        case .connecting(_, let attempt, let autoReconnect):
            return .connecting(generation: nextGeneration, attempt: attempt, autoReconnect: autoReconnect)
        case .connected(_, let attempt, let autoReconnect):
            return .connected(generation: nextGeneration, attempt: attempt, autoReconnect: autoReconnect)
        case .disconnecting(_, let attempt, let manualDisconnect):
            return .disconnecting(
                generation: nextGeneration,
                attempt: attempt,
                manualDisconnect: manualDisconnect
            )
        case .disconnected(_, let attempt, let autoReconnect, let closeCode, let disposition, let error):
            return .disconnected(
                generation: nextGeneration,
                attempt: attempt,
                autoReconnect: autoReconnect,
                closeCode: closeCode,
                disposition: disposition,
                error: error
            )
        case .reconnecting(_, let attempt, let autoReconnect, let closeCode, let disposition, let error):
            return .reconnecting(
                generation: nextGeneration,
                attempt: attempt,
                autoReconnect: autoReconnect,
                closeCode: closeCode,
                disposition: disposition,
                error: error
            )
        case .failed(_, let attempt, let autoReconnect, let closeCode, let disposition, let error):
            return .failed(
                generation: nextGeneration,
                attempt: attempt,
                autoReconnect: autoReconnect,
                closeCode: closeCode,
                disposition: disposition,
                error: error
            )
        }
    }

    package func withAutoReconnectEnabled(_ enabled: Bool) -> Self {
        switch self {
        case .idle(let generation, let attempt, _):
            return .idle(generation: generation, attempt: attempt, autoReconnect: enabled)
        case .connecting(let generation, let attempt, _):
            return .connecting(generation: generation, attempt: attempt, autoReconnect: enabled)
        case .connected(let generation, let attempt, _):
            return .connected(generation: generation, attempt: attempt, autoReconnect: enabled)
        case .disconnecting:
            return self
        case .disconnected(let generation, let attempt, _, let closeCode, let disposition, let error):
            return .disconnected(
                generation: generation,
                attempt: attempt,
                autoReconnect: enabled,
                closeCode: closeCode,
                disposition: disposition,
                error: error
            )
        case .reconnecting(let generation, let attempt, _, let closeCode, let disposition, let error):
            return .reconnecting(
                generation: generation,
                attempt: attempt,
                autoReconnect: enabled,
                closeCode: closeCode,
                disposition: disposition,
                error: error
            )
        case .failed(let generation, let attempt, _, let closeCode, let disposition, let error):
            return .failed(
                generation: generation,
                attempt: attempt,
                autoReconnect: enabled,
                closeCode: closeCode,
                disposition: disposition,
                error: error
            )
        }
    }

    package func withError(_ nextError: WebSocketError?) -> Self {
        switch self {
        case .idle, .connecting, .connected:
            return self
        case .disconnecting(let generation, let attempt, let manualDisconnect):
            return .disconnecting(
                generation: generation,
                attempt: attempt,
                manualDisconnect: WebSocketManualDisconnect(
                    closeCode: manualDisconnect.closeCode,
                    error: nextError
                )
            )
        case .disconnected(let generation, let attempt, let autoReconnect, let closeCode, let disposition, _):
            return .disconnected(
                generation: generation,
                attempt: attempt,
                autoReconnect: autoReconnect,
                closeCode: closeCode,
                disposition: disposition,
                error: nextError
            )
        case .reconnecting(let generation, let attempt, let autoReconnect, let closeCode, let disposition, _):
            return .reconnecting(
                generation: generation,
                attempt: attempt,
                autoReconnect: autoReconnect,
                closeCode: closeCode,
                disposition: disposition,
                error: nextError
            )
        case .failed(let generation, let attempt, let autoReconnect, let closeCode, let disposition, _):
            return .failed(
                generation: generation,
                attempt: attempt,
                autoReconnect: autoReconnect,
                closeCode: closeCode,
                disposition: disposition,
                error: nextError
            )
        }
    }

    package func withCloseCode(_ nextCloseCode: WebSocketCloseCode?) -> Self {
        switch self {
        case .disconnected(let generation, let attempt, let autoReconnect, _, let disposition, let error):
            return .disconnected(
                generation: generation,
                attempt: attempt,
                autoReconnect: autoReconnect,
                closeCode: nextCloseCode,
                disposition: disposition,
                error: error
            )
        case .reconnecting(let generation, let attempt, let autoReconnect, _, let disposition, let error):
            return .reconnecting(
                generation: generation,
                attempt: attempt,
                autoReconnect: autoReconnect,
                closeCode: nextCloseCode,
                disposition: disposition,
                error: error
            )
        case .failed(let generation, let attempt, let autoReconnect, _, let disposition, let error):
            return .failed(
                generation: generation,
                attempt: attempt,
                autoReconnect: autoReconnect,
                closeCode: nextCloseCode,
                disposition: disposition,
                error: error
            )
        case .idle, .connecting, .connected, .disconnecting:
            return self
        }
    }

    package func withCloseDisposition(_ nextDisposition: WebSocketCloseDisposition?) -> Self {
        switch self {
        case .disconnected(let generation, let attempt, let autoReconnect, let closeCode, _, let error):
            return .disconnected(
                generation: generation,
                attempt: attempt,
                autoReconnect: autoReconnect,
                closeCode: closeCode,
                disposition: nextDisposition,
                error: error
            )
        case .reconnecting(let generation, let attempt, let autoReconnect, let closeCode, _, let error):
            return .reconnecting(
                generation: generation,
                attempt: attempt,
                autoReconnect: autoReconnect,
                closeCode: closeCode,
                disposition: nextDisposition,
                error: error
            )
        case .failed(let generation, let attempt, let autoReconnect, let closeCode, _, let error):
            return .failed(
                generation: generation,
                attempt: attempt,
                autoReconnect: autoReconnect,
                closeCode: closeCode,
                disposition: nextDisposition,
                error: error
            )
        case .idle, .connecting, .connected, .disconnecting:
            return self
        }
    }

    package func replacingPublicState(_ nextState: WebSocketState) -> Self {
        let generation = generation
        let attempt = attempt
        let autoReconnect = autoReconnectEnabled

        switch nextState {
        case .idle:
            return .idle(generation: generation, attempt: attempt, autoReconnect: autoReconnect)
        case .connecting:
            return .connecting(generation: generation, attempt: attempt, autoReconnect: autoReconnect)
        case .connected:
            return .connected(generation: generation, attempt: attempt, autoReconnect: autoReconnect)
        case .disconnecting:
            let manualDisconnect =
                manualDisconnect
                ?? WebSocketManualDisconnect(
                    closeCode: closeCode ?? .normalClosure,
                    error: error
                )
            return .disconnecting(
                generation: generation,
                attempt: attempt,
                manualDisconnect: manualDisconnect
            )
        case .disconnected:
            return .disconnected(
                generation: generation,
                attempt: attempt,
                autoReconnect: autoReconnect,
                closeCode: closeCode,
                disposition: closeDisposition,
                error: error
            )
        case .reconnecting:
            return .reconnecting(
                generation: generation,
                attempt: attempt,
                autoReconnect: autoReconnect,
                closeCode: closeCode,
                disposition: closeDisposition,
                error: error
            )
        case .failed:
            return .failed(
                generation: generation,
                attempt: attempt,
                autoReconnect: autoReconnect,
                closeCode: closeCode,
                disposition: closeDisposition,
                error: error
            )
        }
    }
}

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

package enum WebSocketLifecycleReducer: StateReducer {
    package static func reduce(
        state: WebSocketLifecycleState,
        event: WebSocketLifecycleEvent,
        context: WebSocketLifecycleDecisionContext = .init()
    ) -> WebSocketLifecycleTransition {
        switch event {
        case .connect:
            return startConnecting(from: state)
        case .didOpen(let generation, let protocolName):
            return didOpen(from: state, generation: generation, protocolName: protocolName)
        case .manualDisconnect(let closeCode, let error):
            return manualDisconnect(from: state, closeCode: closeCode, error: error)
        case .didClose(let generation, let closeCode, let disposition, let error):
            return didClose(
                from: state,
                generation: generation,
                closeCode: closeCode,
                disposition: disposition,
                error: error,
                context: context
            )
        case .failure(let generation, let disposition, let error):
            return failure(
                from: state,
                generation: generation,
                disposition: disposition,
                error: error,
                context: context
            )
        case .closeTimeout(let closeCode, let error):
            return closeTimeout(from: state, closeCode: closeCode, error: error)
        case .reconnectTimerFired:
            return reconnectTimerFired(from: state)
        case .reset:
            return .init(
                state: .idle(generation: state.generation, attempt: 0, autoReconnect: true),
                effects: [.cancelHeartbeat, .cancelReconnect, .cancelMessageListener, .cancelCloseTimeout]
            )
        }
    }

    private static func startConnecting(from state: WebSocketLifecycleState) -> WebSocketLifecycleTransition {
        let nextGeneration = state.generation + 1
        let nextState = WebSocketLifecycleState.connecting(
            generation: nextGeneration,
            attempt: state.attempt,
            autoReconnect: true
        )
        return .init(
            state: nextState,
            effects: [.cancelReconnect, .startConnection(generation: nextGeneration)]
        )
    }

    private static func didOpen(
        from state: WebSocketLifecycleState,
        generation: Int,
        protocolName: String?
    ) -> WebSocketLifecycleTransition {
        guard generation == state.generation else {
            return .init(state: state, effects: [.ignoreStaleCallback])
        }

        switch state {
        case .connecting(let generation, let attempt, let autoReconnect),
            .reconnecting(let generation, let attempt, let autoReconnect, _, _, _):
            let nextState = WebSocketLifecycleState.connected(
                generation: generation,
                attempt: attempt,
                autoReconnect: autoReconnect
            )
            return .init(
                state: nextState,
                effects: [
                    .cancelReconnect,
                    .startHeartbeat,
                    .publishConnected(protocolName: protocolName),
                ]
            )
        case .disconnecting:
            return .init(state: state, effects: [.ignoreStaleCallback])
        case .idle, .connected, .disconnected, .failed:
            return .init(state: state, effects: [.ignoreStaleCallback])
        }
    }

    private static func manualDisconnect(
        from state: WebSocketLifecycleState,
        closeCode: WebSocketCloseCode,
        error: WebSocketError?
    ) -> WebSocketLifecycleTransition {
        switch state.publicState {
        case .connected, .connecting, .reconnecting:
            let nextState = WebSocketLifecycleState.disconnecting(
                generation: state.generation,
                attempt: state.attempt,
                manualDisconnect: WebSocketManualDisconnect(closeCode: closeCode, error: error)
            )
            return .init(
                state: nextState,
                effects: [
                    .cancelHeartbeat,
                    .cancelReconnect,
                    .cancelMessageListener,
                    .scheduleCloseTimeout(closeCode: closeCode),
                ]
            )
        case .idle, .disconnecting, .disconnected, .failed:
            return .init(state: state, effects: [])
        }
    }

    private static func didClose(
        from state: WebSocketLifecycleState,
        generation: Int,
        closeCode: WebSocketCloseCode,
        disposition: WebSocketCloseDisposition,
        error: WebSocketError?,
        context: WebSocketLifecycleDecisionContext
    ) -> WebSocketLifecycleTransition {
        guard generation == state.generation else {
            return .init(state: state, effects: [.ignoreStaleCallback])
        }

        if case .disconnecting(let generation, let attempt, let manualDisconnect) = state {
            let finalError = manualDisconnect.error ?? error
            let nextState = WebSocketLifecycleState.disconnected(
                generation: generation,
                attempt: attempt,
                autoReconnect: false,
                closeCode: closeCode,
                disposition: .manual(manualDisconnect.closeCode),
                error: finalError
            )
            return .init(
                state: nextState,
                effects: [
                    .cleanupRuntime,
                    .cancelCloseTimeout,
                    .publishDisconnected(error: finalError),
                    .finishTerminal(generation: generation),
                ]
            )
        }

        if state.publicState == .disconnected || state.publicState == .disconnecting || state.publicState == .failed {
            return .init(state: state, effects: [.ignoreStaleCallback])
        }

        let action = context.reconnectAction ?? .terminal
        let attempt = context.attempt ?? state.attempt
        switch action {
        case .retry:
            let nextState = WebSocketLifecycleState.reconnecting(
                generation: state.generation,
                attempt: attempt,
                autoReconnect: state.autoReconnectEnabled,
                closeCode: closeCode,
                disposition: disposition,
                error: error
            )
            return .init(
                state: nextState,
                effects: [
                    .cleanupRuntime,
                    .cancelHeartbeat,
                    .cancelMessageListener,
                    .publishDisconnected(error: error),
                    .scheduleReconnect,
                ]
            )
        case .terminal:
            let nextState = WebSocketLifecycleState.disconnected(
                generation: state.generation,
                attempt: attempt,
                autoReconnect: state.autoReconnectEnabled,
                closeCode: closeCode,
                disposition: disposition,
                error: error
            )
            return .init(
                state: nextState,
                effects: [
                    .cleanupRuntime,
                    .cancelHeartbeat,
                    .cancelMessageListener,
                    .publishDisconnected(error: error),
                    .finishTerminal(generation: state.generation),
                ]
            )
        case .exceeded:
            let finalError = WebSocketError.maxReconnectAttemptsExceeded
            let nextState = WebSocketLifecycleState.failed(
                generation: state.generation,
                attempt: attempt,
                autoReconnect: state.autoReconnectEnabled,
                closeCode: closeCode,
                disposition: disposition,
                error: finalError
            )
            return .init(
                state: nextState,
                effects: [
                    .cleanupRuntime,
                    .cancelHeartbeat,
                    .cancelMessageListener,
                    .publishDisconnected(error: error),
                    .publishError(finalError),
                    .finishTerminal(generation: state.generation),
                ]
            )
        }
    }

    private static func failure(
        from state: WebSocketLifecycleState,
        generation: Int?,
        disposition: WebSocketCloseDisposition,
        error: WebSocketError,
        context: WebSocketLifecycleDecisionContext
    ) -> WebSocketLifecycleTransition {
        if let generation, generation != state.generation {
            return .init(state: state, effects: [.ignoreStaleCallback])
        }

        if state.publicState == .disconnecting || state.publicState.isTerminal {
            return .init(state: state, effects: [.ignoreStaleCallback])
        }

        let action = context.reconnectAction ?? .terminal
        let attempt = context.attempt ?? state.attempt
        switch action {
        case .retry:
            let nextState = WebSocketLifecycleState.reconnecting(
                generation: state.generation,
                attempt: attempt,
                autoReconnect: state.autoReconnectEnabled,
                closeCode: state.closeCode,
                disposition: disposition,
                error: error
            )
            return .init(
                state: nextState,
                effects: [
                    .cleanupRuntime,
                    .cancelHeartbeat,
                    .cancelMessageListener,
                    .publishError(error),
                    .scheduleReconnect,
                ]
            )
        case .terminal:
            let nextState = WebSocketLifecycleState.failed(
                generation: state.generation,
                attempt: attempt,
                autoReconnect: state.autoReconnectEnabled,
                closeCode: state.closeCode,
                disposition: disposition,
                error: error
            )
            return .init(
                state: nextState,
                effects: [
                    .cleanupRuntime,
                    .cancelHeartbeat,
                    .cancelMessageListener,
                    .publishError(error),
                    .finishTerminal(generation: state.generation),
                ]
            )
        case .exceeded:
            let finalError = WebSocketError.maxReconnectAttemptsExceeded
            let nextState = WebSocketLifecycleState.failed(
                generation: state.generation,
                attempt: attempt,
                autoReconnect: state.autoReconnectEnabled,
                closeCode: state.closeCode,
                disposition: disposition,
                error: finalError
            )
            return .init(
                state: nextState,
                effects: [
                    .cleanupRuntime,
                    .cancelHeartbeat,
                    .cancelMessageListener,
                    .publishError(finalError),
                    .finishTerminal(generation: state.generation),
                ]
            )
        }
    }

    private static func closeTimeout(
        from state: WebSocketLifecycleState,
        closeCode: WebSocketCloseCode,
        error: WebSocketError
    ) -> WebSocketLifecycleTransition {
        guard case .disconnecting(let generation, let attempt, _) = state else {
            return .init(state: state, effects: [.ignoreStaleCallback])
        }

        let disposition = WebSocketCloseDisposition.handshakeTimeout(closeCode)
        let nextState = WebSocketLifecycleState.disconnected(
            generation: generation,
            attempt: attempt,
            autoReconnect: false,
            closeCode: closeCode,
            disposition: disposition,
            error: error
        )
        return .init(
            state: nextState,
            effects: [
                .cleanupRuntime,
                .cancelCloseTimeout,
                .publishDisconnected(error: error),
                .finishTerminal(generation: generation),
            ]
        )
    }

    private static func reconnectTimerFired(from state: WebSocketLifecycleState) -> WebSocketLifecycleTransition {
        guard case .reconnecting(_, let attempt, true, _, _, _) = state else {
            return .init(state: state, effects: [.ignoreStaleCallback])
        }

        let nextGeneration = state.generation + 1
        let nextState = WebSocketLifecycleState.connecting(
            generation: nextGeneration,
            attempt: attempt,
            autoReconnect: true
        )
        return .init(
            state: nextState,
            effects: [.startConnection(generation: nextGeneration)]
        )
    }
}
