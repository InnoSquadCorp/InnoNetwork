import Foundation


package enum WebSocketReconnectAction: Equatable {
    case retry
    case terminal
    case exceeded
}

package struct WebSocketReconnectCoordinator {
    let configuration: WebSocketConfiguration
    let runtimeRegistry: WebSocketRuntimeRegistry
    let clock: any InnoNetworkClock

    package init(
        configuration: WebSocketConfiguration,
        runtimeRegistry: WebSocketRuntimeRegistry,
        clock: any InnoNetworkClock = SystemClock()
    ) {
        self.configuration = configuration
        self.runtimeRegistry = runtimeRegistry
        self.clock = clock
    }

    package func reconnectAction(
        task: WebSocketTask,
        previousState: WebSocketState? = nil
    ) async -> WebSocketReconnectAction {
        if let previousState, previousState == .disconnecting {
            return .terminal
        }

        guard await task.autoReconnectEnabled else {
            return .terminal
        }

        let reconnectCount = await task.incrementReconnectCount()
        if reconnectCount <= configuration.maxReconnectAttempts {
            return .retry
        }
        return .exceeded
    }

    package func reconnectAction(
        task: WebSocketTask,
        closeDisposition: WebSocketCloseDisposition,
        previousState: WebSocketState? = nil
    ) async -> WebSocketReconnectAction {
        if let previousState, previousState == .disconnecting {
            return .terminal
        }

        guard closeDisposition.shouldReconnect else {
            return .terminal
        }

        return await reconnectAction(task: task, previousState: previousState)
    }

    package func attemptReconnect(
        task: WebSocketTask,
        startConnection: @escaping @Sendable (WebSocketTask) async -> Void
    ) async {
        let reconnectTask = Task {
            let reconnectCount = await task.reconnectCount
            let baseDelay = configuration.reconnectDelay * pow(2, Double(reconnectCount - 1))
            let jitter = abs(baseDelay * configuration.reconnectJitterRatio)
            let unclamped = max(0.0, baseDelay + Double.random(in: (-jitter)...(jitter)))
            // `maxReconnectDelay <= 0` disables the cap (pre-4.2 unbounded
            // behavior). Otherwise clamp after jitter so the randomized
            // delay never exceeds the configured ceiling.
            let delay: TimeInterval = configuration.maxReconnectDelay > 0
                ? min(unclamped, configuration.maxReconnectDelay)
                : unclamped

            do {
                try await clock.sleep(for: .seconds(delay))
            } catch is CancellationError {
                return
            } catch {
                return
            }

            do {
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard await task.autoReconnectEnabled else { return }
            let state = await task.state
            if Self.shouldReconnect(currentState: state, autoReconnectEnabled: true) {
                await task.updateState(.reconnecting)
                await startConnection(task)
            }
        }

        await runtimeRegistry.setReconnectTask(reconnectTask, for: task.id)
    }

    private static func shouldReconnect(currentState: WebSocketState, autoReconnectEnabled: Bool) -> Bool {
        guard autoReconnectEnabled else { return false }
        switch currentState {
        case .failed, .disconnected, .reconnecting:
            return true
        case .idle, .connecting, .connected, .disconnecting:
            return false
        }
    }
}
