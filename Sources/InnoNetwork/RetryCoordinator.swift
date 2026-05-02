import Foundation

package struct RequestExecutionFailure: Error {
    let error: NetworkError
    let request: URLRequest?
}


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
        do {
            let value = try await runRetryLoop(
                retryPolicy: retryPolicy,
                networkMonitor: networkMonitor,
                requestID: requestID,
                eventObservers: eventObservers,
                operation: operation
            )
            await eventHub.finish(requestID: requestID)
            return value
        } catch {
            // Awaiting `finish` *before* propagating the error guarantees
            // that any drained observer has settled before the caller's
            // `try await client.request(...)` resumes — without this,
            // observer-published-state could be inspected mid-drain.
            await eventHub.finish(requestID: requestID)
            throw error
        }
    }

    private func runRetryLoop<Response>(
        retryPolicy: RetryPolicy?,
        networkMonitor: (any NetworkMonitoring)?,
        requestID: UUID,
        eventObservers: [any NetworkEventObserving],
        operation: @Sendable (Int, UUID) async throws -> Response
    ) async throws -> Response {
        var retryIndex = 0
        var totalRetries = 0
        var snapshot = await networkMonitor?.currentSnapshot()

        while true {
            do {
                try Task.checkCancellation()
                return try await operation(retryIndex, requestID)
            } catch let failure as RequestExecutionFailure {
                let outcome = try await processRetryDecision(
                    error: failure.error,
                    request: failure.request ?? failure.error.underlyingRequest,
                    retryPolicy: retryPolicy,
                    networkMonitor: networkMonitor,
                    requestID: requestID,
                    eventObservers: eventObservers,
                    retryIndex: retryIndex,
                    totalRetries: totalRetries,
                    snapshot: snapshot
                )
                retryIndex = outcome.nextRetryIndex
                totalRetries = outcome.nextTotalRetries
                snapshot = outcome.snapshot
            } catch let error as NetworkError {
                let outcome = try await processRetryDecision(
                    error: error,
                    request: error.underlyingRequest,
                    retryPolicy: retryPolicy,
                    networkMonitor: networkMonitor,
                    requestID: requestID,
                    eventObservers: eventObservers,
                    retryIndex: retryIndex,
                    totalRetries: totalRetries,
                    snapshot: snapshot
                )
                retryIndex = outcome.nextRetryIndex
                totalRetries = outcome.nextTotalRetries
                snapshot = outcome.snapshot
            } catch {
                if NetworkError.isCancellation(error) {
                    let cancellationError = NetworkError.cancelled
                    await eventHub.publish(
                        .requestFailed(
                            requestID: requestID,
                            errorCode: cancellationError.errorCode,
                            message: cancellationError.errorDescription ?? "cancelled"
                        ),
                        requestID: requestID,
                        observers: eventObservers
                    )
                    throw cancellationError
                }
                throw NetworkError.underlying(SendableUnderlyingError(error), nil)
            }
        }
    }

    private struct RetryStepOutcome {
        var nextRetryIndex: Int
        var nextTotalRetries: Int
        var snapshot: NetworkSnapshot?
    }

    private func processRetryDecision(
        error: NetworkError,
        request: URLRequest?,
        retryPolicy: RetryPolicy?,
        networkMonitor: (any NetworkMonitoring)?,
        requestID: UUID,
        eventObservers: [any NetworkEventObserving],
        retryIndex: Int,
        totalRetries: Int,
        snapshot: NetworkSnapshot?
    ) async throws -> RetryStepOutcome {
        guard let policy = retryPolicy else { throw error }
        let decision = policy.shouldRetry(
            error: error,
            retryIndex: retryIndex,
            request: request,
            response: error.underlyingHTTPResponse
        )
        if case .noRetry = decision {
            throw error
        }
        guard totalRetries < policy.maxTotalRetries else {
            throw error
        }

        let computedDelay = policy.retryDelay(for: retryIndex)
        let delay = Self.delay(for: decision, computedDelay: computedDelay, policy: policy)
        await eventHub.publish(
            .retryScheduled(
                requestID: requestID,
                retryIndex: retryIndex,
                delay: delay,
                reason: error.localizedDescription
            ),
            requestID: requestID,
            observers: eventObservers
        )

        var nextRetryIndex = retryIndex + 1
        var nextSnapshot = snapshot
        if policy.waitsForNetworkChanges, let monitor = networkMonitor {
            let newSnapshot = await monitor.waitForChange(
                from: nextSnapshot,
                timeout: policy.networkChangeTimeout
            )
            if policy.shouldResetAttempts(afterNetworkChangeFrom: nextSnapshot, to: newSnapshot) {
                nextRetryIndex = 0
            }
            if let newSnapshot {
                nextSnapshot = newSnapshot
            } else {
                nextSnapshot = await monitor.currentSnapshot() ?? nextSnapshot
            }
        }

        if delay > 0 {
            try await clock.sleep(for: .seconds(delay))
        }

        return RetryStepOutcome(
            nextRetryIndex: nextRetryIndex,
            nextTotalRetries: totalRetries + 1,
            snapshot: nextSnapshot
        )
    }

    private static func delay(
        for decision: RetryDecision,
        computedDelay: TimeInterval,
        policy: RetryPolicy
    ) -> TimeInterval {
        switch decision {
        case .noRetry:
            return computedDelay
        case .retry:
            return computedDelay
        case .retryAfter(let serverHint):
            let hintedDelay = max(serverHint, computedDelay)
            if let maxRetryAfterDelay = policy.maxRetryAfterDelay {
                return min(hintedDelay, max(maxRetryAfterDelay, computedDelay))
            }
            return hintedDelay
        }
    }
}
