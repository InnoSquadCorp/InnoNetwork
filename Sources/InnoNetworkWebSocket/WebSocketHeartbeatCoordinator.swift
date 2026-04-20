import Foundation


/// Tracks the single in-flight `CheckedContinuation` for `sendPing` and folds
/// continuation registration plus ping dispatch into one critical section. The
/// state transitions `idle → waiting → dispatched|cancelled|completed`, so a
/// timeout/cancel that lands after registration but before dispatch can still
/// suppress the outbound ping.
private actor PingContinuationGate {
    enum RegisterAction {
        case dispatched
        case cancelledBeforeRegistration
        case cancelledAfterRegistration
    }

    private enum State {
        case idle
        case waiting(CheckedContinuation<Void, Error>)
        case cancelled
        case completed
    }

    private var state: State = .idle

    func registerAndDispatch(
        _ continuation: CheckedContinuation<Void, Error>,
        beforeDispatch: (@Sendable () async -> Void)? = nil,
        dispatch: () -> Void
    ) async -> RegisterAction {
        switch state {
        case .idle:
            state = .waiting(continuation)
        case .cancelled, .completed, .waiting:
            return .cancelledBeforeRegistration
        }

        if let beforeDispatch {
            await beforeDispatch()
        }

        guard case .waiting = state else { return .cancelledAfterRegistration }
        dispatch()
        return .dispatched
    }

    func resume(with error: Error?) {
        guard case .waiting(let continuation) = state else { return }
        state = .completed
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func cancel() {
        switch state {
        case .idle:
            state = .cancelled
        case .waiting(let continuation):
            state = .cancelled
            continuation.resume(throwing: CancellationError())
        case .cancelled, .completed:
            return
        }
    }
}


package struct WebSocketHeartbeatCoordinator {
    let configuration: WebSocketConfiguration
    let runtimeRegistry: WebSocketRuntimeRegistry
    let eventHub: TaskEventHub<WebSocketEvent>
    let clock: any InnoNetworkClock
    let beforeSendPingDispatch: (@Sendable () async -> Void)?

    package init(
        configuration: WebSocketConfiguration,
        runtimeRegistry: WebSocketRuntimeRegistry,
        eventHub: TaskEventHub<WebSocketEvent>,
        clock: any InnoNetworkClock = SystemClock(),
        beforeSendPingDispatch: (@Sendable () async -> Void)? = nil
    ) {
        self.configuration = configuration
        self.runtimeRegistry = runtimeRegistry
        self.eventHub = eventHub
        self.clock = clock
        self.beforeSendPingDispatch = beforeSendPingDispatch
    }

    package func startHeartbeat(
        for task: WebSocketTask,
        onPingTimeout: @escaping @Sendable (Int) async -> Void
    ) async {
        await runtimeRegistry.cancelHeartbeatTask(for: task.id)
        guard configuration.heartbeatInterval > 0 else { return }

        let heartbeatTask = Task {
            var missedPongs = 0
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(configuration.heartbeatInterval))
                } catch is CancellationError {
                    break
                } catch {
                    break
                }

                if Task.isCancelled { break }

                let state = await task.state
                if state != .connected { break }

                guard let urlTask = await runtimeRegistry.urlTask(for: task.id) else { break }

                await eventHub.publish(.ping, for: task.id)
                do {
                    try await sendPing(urlTask, timeout: configuration.pongTimeout)
                    missedPongs = 0
                    await eventHub.publish(.pong, for: task.id)
                } catch {
                    missedPongs += 1
                    if missedPongs >= configuration.maxMissedPongs {
                        await onPingTimeout(urlTask.taskIdentifier)
                        break
                    }
                }
            }
        }

        await runtimeRegistry.setHeartbeatTask(heartbeatTask, for: task.id)
    }

    package func sendPing(_ urlTask: any WebSocketURLTask) async throws {
        // Be explicit about cancellation: the pong handler may never fire if
        // the underlying task is torn down (e.g. `sendPing(_:timeout:)` cancels
        // this subtask after a pingTimeout). Without a cancellation handler
        // the continuation leaks and the enclosing task group deadlocks.
        let gate = PingContinuationGate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Task {
                    let action = await gate.registerAndDispatch(
                        continuation,
                        beforeDispatch: beforeSendPingDispatch
                    ) {
                        urlTask.sendPing { error in
                            Task {
                                await gate.resume(with: error)
                            }
                        }
                    }
                    if case .cancelledBeforeRegistration = action {
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task {
                await gate.cancel()
            }
        }
    }

    package func sendPing(
        _ urlTask: any WebSocketURLTask,
        timeout: TimeInterval
    ) async throws {
        guard timeout > 0 else {
            try await sendPing(urlTask)
            return
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                try await self.sendPing(urlTask)
            }
            group.addTask { [clock] in
                try await clock.sleep(for: .seconds(timeout))
                throw WebSocketInternalError.pingTimeout
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}
