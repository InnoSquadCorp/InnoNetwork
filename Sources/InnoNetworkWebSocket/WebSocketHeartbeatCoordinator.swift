import Foundation
import os


/// Tracks the single in-flight `CheckedContinuation` for `sendPing`. The state
/// transitions `idle → registered → (resumed | cancelled)`, with `cancelled`
/// reachable from either `idle` (cancel-before-register) or `registered`
/// (cancel-during-wait). Every path resumes the continuation exactly once.
private final class PingContinuationState: @unchecked Sendable {
    enum RegisterAction { case registered, cancelled }

    private struct State {
        var continuation: CheckedContinuation<Void, Error>?
        var cancelled: Bool = false
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    func register(_ continuation: CheckedContinuation<Void, Error>) -> RegisterAction {
        lock.withLock { state in
            if state.cancelled { return .cancelled }
            state.continuation = continuation
            return .registered
        }
    }

    func takeContinuation() -> CheckedContinuation<Void, Error>? {
        lock.withLock { state in
            let c = state.continuation
            state.continuation = nil
            return c
        }
    }

    func cancel() -> CheckedContinuation<Void, Error>? {
        lock.withLock { state in
            state.cancelled = true
            let c = state.continuation
            state.continuation = nil
            return c
        }
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
        let state = PingContinuationState()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let action = state.register(continuation)
                switch action {
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .registered:
                    urlTask.sendPing { error in
                        guard let resume = state.takeContinuation() else { return }
                        if let error {
                            resume.resume(throwing: error)
                        } else {
                            resume.resume()
                        }
                    }
                }
            }
        } onCancel: {
            if let resume = state.cancel() {
                resume.resume(throwing: CancellationError())
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
