import Foundation


package struct RetryCoordinator {
    private let eventHub: NetworkEventHub

    package init(eventHub: NetworkEventHub) {
        self.eventHub = eventHub
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
                guard let policy = retryPolicy, policy.shouldRetry(error: error, retryIndex: retryIndex) else {
                    throw error
                }
                guard totalRetries < policy.maxTotalRetries else {
                    throw error
                }

                let currentRetryIndex = retryIndex
                let delay = policy.retryDelay(for: currentRetryIndex)
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
                    try await Task.sleep(for: .seconds(delay))
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
