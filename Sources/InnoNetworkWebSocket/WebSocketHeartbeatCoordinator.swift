import Foundation


/// Tracks the single in-flight `CheckedContinuation` for `sendPing`. The state
/// transitions `idle → registered → (resumed | cancelled)`, with `cancelled`
/// reachable from either `idle` (cancel-before-register) or `registered`
/// (cancel-during-wait). Every path resumes the continuation exactly once.
private actor PingContinuationGate {
    enum RegisterAction { case registered, cancelled }
    
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    func register(_ continuation: CheckedContinuation<Void, Error>) -> RegisterAction {
        if cancelled { return .cancelled }
        self.continuation = continuation
        return .registered
    }

    func resume(with error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func cancel() {
        cancelled = true
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: CancellationError())
    }
}


package struct WebSocketHeartbeatCoordinator {
    let configuration: WebSocketConfiguration
    let runtimeRegistry: WebSocketRuntimeRegistry
    let eventHub: TaskEventHub<WebSocketEvent>
    let clock: any InnoNetworkClock

    package init(
        configuration: WebSocketConfiguration,
        runtimeRegistry: WebSocketRuntimeRegistry,
        eventHub: TaskEventHub<WebSocketEvent>,
        clock: any InnoNetworkClock = SystemClock()
    ) {
        self.configuration = configuration
        self.runtimeRegistry = runtimeRegistry
        self.eventHub = eventHub
        self.clock = clock
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
                    let action = await gate.register(continuation)
                    switch action {
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case .registered:
                        urlTask.sendPing { error in
                            Task {
                                await gate.resume(with: error)
                            }
                        }
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
