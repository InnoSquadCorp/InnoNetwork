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
    let randomOffset: @Sendable (ClosedRange<Double>) -> Double

    package init(
        configuration: WebSocketConfiguration,
        runtimeRegistry: WebSocketRuntimeRegistry,
        clock: any InnoNetworkClock = SystemClock(),
        randomOffset: @escaping @Sendable (ClosedRange<Double>) -> Double = { range in
            Double.random(in: range)
        }
    ) {
        self.configuration = configuration
        self.runtimeRegistry = runtimeRegistry
        self.clock = clock
        self.randomOffset = randomOffset
    }

    /// Increments the task's reconnect counter and returns the resulting
    /// action.
    ///
    /// The counter is bumped **before** the cap check, so the rejected
    /// attempt that produces `.exceeded` is itself counted. Consumers that
    /// observe ``WebSocketTask/reconnectCount`` during the failure
    /// transition may briefly see `maxReconnectAttempts + 1`. That overshoot
    /// is intentional — it represents "we tried, and even this attempt was
    /// over the limit" rather than "we stopped before trying."
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
            let delay = reconnectDelay(forAttempt: reconnectCount)

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

    private func reconnectDelay(forAttempt reconnectCount: Int) -> TimeInterval {
        let baseDelay = configuration.reconnectDelay * pow(2, Double(reconnectCount - 1))

        guard configuration.maxReconnectDelay > 0 else {
            let jitter = abs(baseDelay * configuration.reconnectJitterRatio)
            return max(0.0, baseDelay + randomOffset((-jitter)...(jitter)))
        }

        let cappedBase = min(baseDelay, configuration.maxReconnectDelay)
        let jitter = abs(cappedBase * configuration.reconnectJitterRatio)
        let lowerBound = max(0.0, cappedBase - jitter)
        let upperBound = min(configuration.maxReconnectDelay, cappedBase + jitter)
        return randomOffset(lowerBound...upperBound)
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
