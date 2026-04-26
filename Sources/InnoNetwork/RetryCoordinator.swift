import Foundation


package struct RetryCoordinator {
    private let eventHub: NetworkEventHub
    private let clock: any InnoNetworkClock

    package init(
        eventHub: NetworkEventHub,
        clock: any InnoNetworkClock = SystemClock()
    ) {
        self.eventHub = eventHub
        self.clock = clock
    }

    package func execute<Response>(
        retryPolicy: RetryPolicy?,
        networkMonitor: (any NetworkMonitoring)?,
        requestID: UUID,
        eventObservers: [any NetworkEventObserving],
        operation: @Sendable (Int, UUID) async throws -> Response
    ) async throws -> Response {
        defer {
            Task {
                await eventHub.finish(requestID: requestID)
            }
        }

        var retryIndex = 0
        var totalRetries = 0
        var snapshot = await networkMonitor?.currentSnapshot()

        while true {
            do {
                try Task.checkCancellation()
                return try await operation(retryIndex, requestID)
            } catch let error as NetworkError {
                guard let policy = retryPolicy else { throw error }
                let decision = policy.shouldRetry(
                    error: error,
                    retryIndex: retryIndex,
                    request: error.underlyingRequest,
                    response: error.underlyingHTTPResponse
                )
                if case .noRetry = decision {
                    throw error
                }
                guard totalRetries < policy.maxTotalRetries else {
                    throw error
                }

                let currentRetryIndex = retryIndex
                let computedDelay = policy.retryDelay(for: currentRetryIndex)
                // Honor server hint when present, but never less than the
                // computed jittered delay and never more than 4× that — an
                // adversarial server cannot stall the client indefinitely.
                let delay: TimeInterval
                switch decision {
                case .noRetry:
                    // Unreachable: handled above; keeps the switch exhaustive.
                    throw error
                case .retry:
                    delay = computedDelay
                case .retryAfter(let serverHint):
                    let upperBound = max(computedDelay, policy.retryDelay) * 4
                    delay = min(max(serverHint, computedDelay), upperBound)
                }
                await eventHub.publish(
                    .retryScheduled(
                        requestID: requestID,
                        retryIndex: currentRetryIndex,
                        delay: delay,
                        reason: error.localizedDescription
                    ),
                    requestID: requestID,
                    observers: eventObservers
                )
                totalRetries += 1

                var nextRetryIndex = currentRetryIndex + 1
                if policy.waitsForNetworkChanges, let monitor = networkMonitor {
                    let newSnapshot = await monitor.waitForChange(
                        from: snapshot,
                        timeout: policy.networkChangeTimeout
                    )
                    if policy.shouldResetAttempts(afterNetworkChangeFrom: snapshot, to: newSnapshot) {
                        nextRetryIndex = 0
                    }
                    if let newSnapshot {
                        snapshot = newSnapshot
                    } else {
                        snapshot = await monitor.currentSnapshot() ?? snapshot
                    }
                }

                if delay > 0 {
                    try await clock.sleep(for: .seconds(delay))
                }
                retryIndex = nextRetryIndex
            } catch {
                if NetworkError.isCancellation(error) {
                    throw NetworkError.cancelled
                }
                throw NetworkError.underlying(SendableUnderlyingError(error), nil)
            }
        }
    }
}
