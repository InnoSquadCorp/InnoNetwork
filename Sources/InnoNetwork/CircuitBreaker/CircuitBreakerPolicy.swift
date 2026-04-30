import Foundation

/// Per-host circuit breaker policy for short-circuiting repeated failures.
public struct CircuitBreakerPolicy: Sendable, Equatable {
    public let failureThreshold: Int
    public let windowSize: Int
    public let resetAfter: Duration
    public let maxResetAfter: Duration

    public init(
        failureThreshold: Int = 5,
        windowSize: Int = 10,
        resetAfter: Duration = .seconds(30),
        maxResetAfter: Duration = .seconds(300)
    ) {
        let normalizedWindowSize = max(1, windowSize)
        let normalizedResetAfter = max(.zero, resetAfter)

        self.windowSize = normalizedWindowSize
        self.failureThreshold = min(max(1, failureThreshold), normalizedWindowSize)
        self.resetAfter = normalizedResetAfter
        self.maxResetAfter = max(normalizedResetAfter, maxResetAfter)
    }
}


/// Error wrapped by ``NetworkError/underlying(_:_:)`` when a circuit is open.
public struct CircuitBreakerOpenError: Error, Sendable, Equatable, LocalizedError, CustomNSError {
    public static let errorDomain = "com.innosquad.innonetwork.circuit-breaker"

    public let host: String
    public let retryAfter: TimeInterval

    public init(host: String, retryAfter: TimeInterval) {
        self.host = host
        self.retryAfter = max(0, retryAfter)
    }

    public var errorDescription: String? {
        "Circuit breaker is open for \(host). Retry after \(retryAfter) seconds."
    }

    public var errorCode: Int { 1 }
}


package actor CircuitBreakerRegistry {
    private enum Mode {
        case closed([Bool])
        case open(until: Date, resetAfter: Duration)
        case halfOpen(probeInFlight: Bool, resetAfter: Duration)
    }

    private var states: [String: Mode] = [:]

    package init() {}

    package func prepare(request: URLRequest, policy: CircuitBreakerPolicy?) throws {
        guard policy != nil, let host = request.url?.host else { return }
        let now = Date()
        let mode = states[host] ?? .closed([])
        switch mode {
        case .closed:
            return
        case .open(let until, let resetAfter):
            if now >= until {
                states[host] = .halfOpen(probeInFlight: true, resetAfter: resetAfter)
                return
            }
            throw NetworkError.underlying(
                SendableUnderlyingError(CircuitBreakerOpenError(host: host, retryAfter: until.timeIntervalSince(now))),
                nil
            )
        case .halfOpen(let probeInFlight, let resetAfter):
            guard !probeInFlight else {
                throw NetworkError.underlying(
                    SendableUnderlyingError(CircuitBreakerOpenError(host: host, retryAfter: resetAfter.timeInterval)),
                    nil
                )
            }
            states[host] = .halfOpen(probeInFlight: true, resetAfter: resetAfter)
        }
    }

    package func recordSuccess(request: URLRequest, policy: CircuitBreakerPolicy?) {
        guard policy != nil, let host = request.url?.host else { return }
        states[host] = .closed([])
    }

    package func recordFailure(request: URLRequest, policy: CircuitBreakerPolicy?, error: Error) {
        guard let policy, let host = request.url?.host else { return }
        guard isCountable(error: error) else { return }
        recordCountableFailure(host: host, policy: policy)
    }

    package func recordStatus(request: URLRequest, policy: CircuitBreakerPolicy?, statusCode: Int) {
        guard let policy, let host = request.url?.host else { return }
        if (500...599).contains(statusCode) {
            recordCountableFailure(host: host, policy: policy)
        } else {
            states[host] = .closed([])
        }
    }

    /// Releases a half-open probe slot when the probe is cancelled before it
    /// can record success or failure. Without this the host would stay in
    /// `halfOpen(probeInFlight: true)` and reject every subsequent request.
    package func recordCancellation(request: URLRequest, policy: CircuitBreakerPolicy?) {
        guard policy != nil, let host = request.url?.host else { return }
        if case .halfOpen = states[host] {
            states[host] = .closed([])
        }
    }

    private func recordCountableFailure(host: String, policy: CircuitBreakerPolicy) {
        let mode = states[host] ?? .closed([])
        switch mode {
        case .closed(let failures):
            var updated = failures
            updated.append(true)
            if updated.count > policy.windowSize {
                updated.removeFirst(updated.count - policy.windowSize)
            }
            if updated.count >= policy.failureThreshold {
                states[host] = .open(
                    until: Date().addingTimeInterval(policy.resetAfter.timeInterval), resetAfter: policy.resetAfter)
            } else {
                states[host] = .closed(updated)
            }
        case .open:
            return
        case .halfOpen(_, let resetAfter):
            let doubled = min(resetAfter.timeInterval * 2, policy.maxResetAfter.timeInterval)
            let next = Duration.milliseconds(Int64((doubled * 1000).rounded()))
            states[host] = .open(until: Date().addingTimeInterval(next.timeInterval), resetAfter: next)
        }
    }

    private func isCountable(error: Error) -> Bool {
        if let networkError = error as? NetworkError {
            switch networkError {
            case .timeout, .nonHTTPResponse:
                return true
            case .underlying(let underlying, _):
                return !NetworkError.isCancellation(underlying)
            default:
                return false
            }
        }
        return !NetworkError.isCancellation(error)
    }
}
