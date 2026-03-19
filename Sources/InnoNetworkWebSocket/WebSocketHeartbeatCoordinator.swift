import Foundation


package struct WebSocketHeartbeatCoordinator {
    let configuration: WebSocketConfiguration
    let runtimeRegistry: WebSocketRuntimeRegistry
    let eventHub: TaskEventHub<WebSocketEvent>

    package init(
        configuration: WebSocketConfiguration,
        runtimeRegistry: WebSocketRuntimeRegistry,
        eventHub: TaskEventHub<WebSocketEvent>
    ) {
        self.configuration = configuration
        self.runtimeRegistry = runtimeRegistry
        self.eventHub = eventHub
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
                    try await Task.sleep(for: .seconds(configuration.heartbeatInterval))
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

    package func sendPing(_ urlTask: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            urlTask.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    package func sendPing(
        _ urlTask: URLSessionWebSocketTask,
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
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw WebSocketInternalError.pingTimeout
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}
