import Foundation
import InnoNetwork

// Split out of `WebSocketManager.swift` so the URLSession delegate-bridge —
// nonisolated yield entry points, on-actor consumer (`processDelegateEvent`
// and the four `process*` reducers), and the URLError → WebSocketError
// classifier — lives in one place. All methods stay actor-isolated except
// the nonisolated bridges.
extension WebSocketManager {

    func processDelegateEvent(_ event: DelegateEvent) async {
        // `AsyncStream.Continuation.finish()` drains elements that were
        // already buffered. The lock-backed shutdown flag rejects that
        // backlog, while shutdown awaits the single consumer before starting
        // its terminal sweep. An event that passes this guard therefore runs
        // to completion before shutdown can mutate or remove its task.
        guard !isShutdown else { return }

        switch event {
        case .connected(let taskIdentifier, let protocolName):
            await processConnected(taskIdentifier: taskIdentifier, protocolName: protocolName)
        case .disconnected(let taskIdentifier, let closeCode, let reason):
            await processDisconnected(taskIdentifier: taskIdentifier, closeCode: closeCode, reason: reason)
        case .mappedError(let taskIdentifier, let error):
            await processMappedError(taskIdentifier: taskIdentifier, error: error)
        case .redirectRejected(let taskIdentifier, let error):
            await processRedirectRejected(taskIdentifier: taskIdentifier, error: error)
        case .sessionError(let taskIdentifier, let error, let statusCode):
            await processSessionError(taskIdentifier: taskIdentifier, error: error, statusCode: statusCode)
        case .pingTimeout(let taskIdentifier):
            await processPingTimeout(taskIdentifier: taskIdentifier)
        }
    }

    /// Suspends until the manager has fully processed every delegate
    /// callback delivered before this call.
    ///
    /// Delegate callbacks are queued and reduced one at a time, so a test
    /// that injects a callback and then changes task state must wait for the
    /// injected callback to be reduced first. A timed pause cannot guarantee
    /// that under load; this barrier can. Package-scoped: it exists for the
    /// repository's own tests.
    package nonisolated func waitForDelegateEventsProcessed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let result = delegateEventContinuation.yield(.flush { continuation.resume() })
            if case .enqueued = result {
                return
            }
            // The stream already finished (shutdown) or dropped the element,
            // so the consumer will never reach the flush marker.
            continuation.resume()
        }
    }

    nonisolated func handleConnected(taskIdentifier: Int, protocolName: String?) {
        delegateEventContinuation.yield(
            .event(.connected(taskIdentifier: taskIdentifier, protocolName: protocolName))
        )
    }

    nonisolated func handleDisconnected(taskIdentifier: Int, closeCode: WebSocketCloseCode, reason: String?) {
        delegateEventContinuation.yield(
            .event(.disconnected(taskIdentifier: taskIdentifier, closeCode: closeCode, reason: reason))
        )
    }

    nonisolated func handleError(taskIdentifier: Int, error: Error) {
        let wsError = Self.mapWebSocketError(error)
        delegateEventContinuation.yield(
            .event(.mappedError(taskIdentifier: taskIdentifier, error: wsError))
        )
    }

    nonisolated func handleSessionError(taskIdentifier: Int, error: SendableUnderlyingError, statusCode: Int? = nil) {
        delegateEventContinuation.yield(
            .event(.sessionError(taskIdentifier: taskIdentifier, error: error, statusCode: statusCode))
        )
    }

    nonisolated func handleRedirectRejected(taskIdentifier: Int, error: WebSocketError) {
        delegateEventContinuation.yield(
            .event(.redirectRejected(taskIdentifier: taskIdentifier, error: error))
        )
    }

    nonisolated func handlePingTimeout(taskIdentifier: Int) {
        delegateEventContinuation.yield(.event(.pingTimeout(taskIdentifier: taskIdentifier)))
    }

    func processConnected(taskIdentifier: Int, protocolName: String?) async {
        guard let callbackContext = await runtimeRegistry.callbackContext(for: taskIdentifier),
            await acquireTaskLifecycleGate(
                for: callbackContext,
                taskIdentifier: taskIdentifier
            )
        else { return }
        let task = callbackContext.task
        let hadConnectedBefore = await task.hasConnectedBefore
        let transition = await task.applyLifecycleEvent(
            .didOpen(generation: callbackContext.generation, protocolName: protocolName)
        )
        let didConnect = transition.state.publicState == .connected && !transition.isIgnoredCallback

        // Only a connection that re-enters `.connected` is a reconnect. The
        // public state at `didOpen` cannot tell one from a first connection,
        // and neither can the attempt counter: a first connection whose
        // handshake failed and was retried also has attempts behind it.
        if didConnect, hadConnectedBefore {
            await task.incrementSuccessfulReconnectCount()
        }
        if didConnect {
            await reconnectCoordinator.connectionDidOpen(task: task)
            await task.resetPingCounter()
            await task.setAutoReconnectEnabled(true)
            await task.setError(nil)
        }
        await executeLifecycleEffectsAfterLockedApply(transition, for: task)
    }

    func processDisconnected(taskIdentifier: Int, closeCode: WebSocketCloseCode, reason: String?) async {
        guard let callbackContext = await runtimeRegistry.callbackContext(for: taskIdentifier),
            await acquireTaskLifecycleGate(
                for: callbackContext,
                taskIdentifier: taskIdentifier
            )
        else { return }
        let task = callbackContext.task
        let previousState = await task.state
        let isManualClose = await task.awaitingCloseHandshake
        let disposition: WebSocketCloseDisposition
        let error: WebSocketError?
        let context: WebSocketLifecycleDecisionContext

        if isManualClose {
            disposition = .manual(closeCode)
            error = await task.currentLifecycleState.manualDisconnect?.error
            context = .init()
        } else {
            disposition = WebSocketCloseDisposition.classifyPeerClose(
                closeCode,
                reason: reason
            )
            error = makeDisconnectedError(closeDisposition: disposition)
            let currentGeneration = await task.connectionGeneration
            if callbackContext.generation != currentGeneration
                || previousState == .disconnecting
                || previousState == .disconnected
                || previousState == .failed
            {
                context = .init()
            } else {
                let reconnectAction = await reconnectCoordinator.reconnectAction(
                    task: task,
                    closeDisposition: disposition,
                    previousState: previousState
                )
                context = .init(
                    reconnectAction: reconnectAction,
                    attempt: await task.attemptedReconnectCount
                )
            }
        }

        let transition = await task.applyLifecycleEvent(
            .didClose(
                generation: callbackContext.generation,
                closeCode: closeCode,
                disposition: disposition,
                error: error
            ),
            context: context
        )
        await executeLifecycleEffectsAfterLockedApply(transition, for: task)
    }

    func processMappedError(taskIdentifier: Int, error wsError: WebSocketError) async {
        if case .cancelled = wsError {
            return
        }
        await handleMappedError(taskIdentifier: taskIdentifier, error: wsError)
    }

    func processRedirectRejected(taskIdentifier: Int, error: WebSocketError) async {
        guard let callbackContext = await runtimeRegistry.callbackContext(for: taskIdentifier),
            await acquireTaskLifecycleGate(
                for: callbackContext,
                taskIdentifier: taskIdentifier
            )
        else { return }

        let transition = await callbackContext.task.applyLifecycleEvent(
            .failure(
                generation: callbackContext.generation,
                disposition: .transportFailure(error),
                error: error
            ),
            context: .init(reconnectAction: .terminal)
        )
        await executeLifecycleEffectsAfterLockedApply(transition, for: callbackContext.task)
    }

    func processPingTimeout(taskIdentifier: Int) async {
        await handleMappedError(taskIdentifier: taskIdentifier, error: .pingTimeout)
    }

    func processSessionError(
        taskIdentifier: Int,
        error: SendableUnderlyingError,
        statusCode: Int?
    ) async {
        guard !Self.isCancelledTransportError(error) else { return }
        guard let callbackContext = await runtimeRegistry.callbackContext(for: taskIdentifier),
            await acquireTaskLifecycleGate(
                for: callbackContext,
                taskIdentifier: taskIdentifier
            )
        else { return }

        let task = callbackContext.task
        let state = await task.state
        if state == .connecting || state == .reconnecting {
            let disposition = WebSocketCloseDisposition.classifyHandshake(
                statusCode: statusCode,
                error: error
            )
            await handleFailureHoldingLifecycleGate(
                callbackContext: callbackContext,
                closeDisposition: disposition,
                previousState: state
            )
            return
        }

        let wsError: WebSocketError = Self.isTimeoutTransportError(error) ? .pingTimeout : .connectionFailed(error)
        await handleFailureHoldingLifecycleGate(
            callbackContext: callbackContext,
            closeDisposition: .transportFailure(wsError)
        )
    }

    nonisolated static func mapWebSocketError(_ error: Error) -> WebSocketError {
        if let internalError = error as? WebSocketInternalError {
            switch internalError {
            case .pingTimeout:
                return .pingTimeout
            }
        }

        if let webSocketError = error as? WebSocketError {
            return webSocketError
        }

        if error is CancellationError {
            return .cancelled
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .timedOut:
                return .pingTimeout
            default:
                return .connectionFailed(SendableUnderlyingError(error))
            }
        }

        return .connectionFailed(SendableUnderlyingError(error))
    }

    nonisolated static func isCancelledTransportError(_ error: SendableUnderlyingError) -> Bool {
        error.domain == NSURLErrorDomain && error.code == URLError.cancelled.rawValue
    }

    nonisolated static func isTimeoutTransportError(_ error: SendableUnderlyingError) -> Bool {
        error.domain == NSURLErrorDomain && error.code == URLError.timedOut.rawValue
    }
}
