import Foundation
import InnoNetwork

// Split out of `WebSocketLifecycleReducer.swift` so the lifecycle state
// model — the seven-case enum plus its accessors and `withX` /
// `replacingX` transformers — lives in one place. The reducer file
// keeps only the `WebSocketLifecycleReducer.reduce` entry point and its
// private helpers. All types stay `package`; this file only relocates
// code, no behaviour changes.

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
