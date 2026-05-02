import Foundation

package enum WebSocketReconnectAction: Equatable {
    case retry
    case terminal
    case exceeded(reason: ExceededReason)

    package enum ExceededReason: Equatable {
        case attempts
        case duration
    }
}

package struct WebSocketReconnectCoordinator {
    let configuration: WebSocketConfiguration
    let runtimeRegistry: WebSocketRuntimeRegistry
    let clock: any InnoNetworkClock
    let randomOffset: @Sendable (ClosedRange<Double>) -> Double
    let dateProvider: @Sendable () -> Date
    let eventHub: TaskEventHub<WebSocketEvent>?

    package init(
        configuration: WebSocketConfiguration,
        runtimeRegistry: WebSocketRuntimeRegistry,
        clock: any InnoNetworkClock = SystemClock(),
        randomOffset: @escaping @Sendable (ClosedRange<Double>) -> Double = { range in
            Double.random(in: range)
        },
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        eventHub: TaskEventHub<WebSocketEvent>? = nil
    ) {
        self.configuration = configuration
        self.runtimeRegistry = runtimeRegistry
        self.clock = clock
        self.randomOffset = randomOffset
        self.dateProvider = dateProvider
        self.eventHub = eventHub
    }

    /// Increments the task's attempted-reconnect counter and returns the
    /// resulting action.
    ///
    /// The counter is bumped **before** the cap check, so the rejected
    /// attempt that produces `.exceeded` is itself counted. Consumers that
    /// observe ``WebSocketTask/attemptedReconnectCount`` during the failure
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

        // Stamp the reconnect-window if this is the first reconnect attempt
        // after a clean connection. The stamp is cleared by the manager once
        // a reconnect succeeds or the task is reset.
        let now = dateProvider()
        await task.beginReconnectWindowIfNeeded(now: now)

        if configuration.reconnectMaxTotalDuration > 0,
           let started = await task.reconnectWindowStartedAt,
           now.timeIntervalSince(started) > configuration.reconnectMaxTotalDuration
        {
            // Bump the counter so observers see the rejected attempt before
            // returning .exceeded — mirrors the maxReconnectAttempts semantics.
            _ = await task.incrementAttemptedReconnectCount()
            return .exceeded(reason: .duration)
        }

        let reconnectCount = await task.incrementAttemptedReconnectCount()
        if reconnectCount <= configuration.maxReconnectAttempts {
            return .retry
        }
        return .exceeded(reason: .attempts)
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
        // Cancel any prior reconnect task before installing a new one. We do
        // this explicitly here (in addition to setReconnectTask's swap-and-
        // cancel) so the new Task we are about to spawn never overlaps with
        // a stale predecessor's clock waiter — both would otherwise race the
        // shared TestClock and/or fire a pair of startConnection callbacks
        // under rapid disconnect bursts.
        await runtimeRegistry.cancelReconnectTask(for: task.id)

        let reconnectTask = Task { [eventHub] in
            let reconnectCount = await task.attemptedReconnectCount
            let delay = reconnectDelay(forAttempt: reconnectCount)

            do {
                try await clock.sleep(for: .seconds(delay))
            } catch is CancellationError {
                return
            } catch {
                // Sleep failed for a reason other than cancellation. The
                // previous behaviour silently dropped the reconnect attempt;
                // surface a paired error event so observers can correlate the
                // skipped retry with their telemetry instead of seeing the
                // socket stall in `.reconnecting` forever.
                if let eventHub {
                    await eventHub.publish(.error(.unknown), for: task.id)
                }
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
                await startConnection(task)
            }
        }

        await runtimeRegistry.setReconnectTask(reconnectTask, for: task.id)
    }

    private func reconnectDelay(forAttempt reconnectCount: Int) -> TimeInterval {
        // `pow(2, -1)` would shrink the base delay below the configured
        // floor when `reconnectCount == 0`. Clamp the exponent so the very
        // first reconnect always uses the configured `reconnectDelay` as the
        // floor (count=1 → 2^0 = 1×, matching exponential expectations).
        let safeCount = max(1, reconnectCount)
        let baseDelay = configuration.reconnectDelay * pow(2, Double(safeCount - 1))

        guard configuration.maxReconnectDelay > 0 else {
            let jitter = abs(baseDelay * configuration.reconnectJitterRatio)
            let lowerBound = -jitter
            let upperBound = jitter
            return max(0.0, baseDelay + sample(lowerBound...upperBound))
        }

        let cappedBase = min(baseDelay, configuration.maxReconnectDelay)
        let jitter = abs(cappedBase * configuration.reconnectJitterRatio)
        let lowerBound = max(0.0, cappedBase - jitter)
        let upperBound = min(configuration.maxReconnectDelay, cappedBase + jitter)
        return sample(lowerBound...upperBound)
    }

    /// Clamp inverted bounds before delegating to ``randomOffset``. Floating-
    /// point cancellation (e.g. tiny `cappedBase - jitter` undershoot when
    /// jitter ≥ cappedBase) can otherwise produce `lowerBound > upperBound`,
    /// which traps inside the standard library's `Range`/`ClosedRange`
    /// initializer.
    private func sample(_ range: ClosedRange<Double>) -> Double {
        if range.lowerBound <= range.upperBound {
            return randomOffset(range)
        }
        let mid = range.upperBound
        return randomOffset(mid...mid)
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
