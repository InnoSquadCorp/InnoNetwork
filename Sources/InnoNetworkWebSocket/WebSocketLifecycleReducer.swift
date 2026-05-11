import Foundation
import InnoNetwork

// The lifecycle state model and the reducer's input/output value types
// live in `WebSocketLifecycleState.swift` and
// `WebSocketLifecycleEvents.swift`. This file keeps only the pure
// `reduce` entry point and its per-event helpers, so the reducer's
// transition table can be read end-to-end without scrolling past the
// data model.
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
        case .exceeded(let reason):
            let finalError: WebSocketError = {
                switch reason {
                case .attempts: return .maxReconnectAttemptsExceeded
                case .duration: return .reconnectWindowExceeded
                }
            }()
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
        case .exceeded(let reason):
            let finalError: WebSocketError = {
                switch reason {
                case .attempts: return .maxReconnectAttemptsExceeded
                case .duration: return .reconnectWindowExceeded
                }
            }()
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
