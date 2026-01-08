import Foundation


public protocol RetryPolicy: Sendable {
    var maxRetries: Int { get }
    var retryDelay: TimeInterval { get }
    func shouldRetry(error: NetworkError, attempt: Int) -> Bool
    var waitsForNetworkChanges: Bool { get }
    var networkChangeTimeout: TimeInterval? { get }
    func shouldResetAttempts(afterNetworkChangeFrom oldSnapshot: NetworkSnapshot?, to newSnapshot: NetworkSnapshot?) -> Bool
}

public extension RetryPolicy {
    var waitsForNetworkChanges: Bool { false }
    var networkChangeTimeout: TimeInterval? { nil }
    func shouldResetAttempts(afterNetworkChangeFrom oldSnapshot: NetworkSnapshot?, to newSnapshot: NetworkSnapshot?) -> Bool {
        false
    }

    func retryDelay(for attempt: Int) -> TimeInterval {
        retryDelay
    }
}

public struct ExponentialBackoffRetryPolicy: RetryPolicy {
    public let maxRetries: Int
    public let retryDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let jitterRatio: Double
    public let waitsForNetworkChanges: Bool
    public let networkChangeTimeout: TimeInterval?

    public init(
        maxRetries: Int = 3,
        retryDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        jitterRatio: Double = 0.2,
        waitsForNetworkChanges: Bool = true,
        networkChangeTimeout: TimeInterval? = 10.0
    ) {
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.maxDelay = maxDelay
        self.jitterRatio = jitterRatio
        self.waitsForNetworkChanges = waitsForNetworkChanges
        self.networkChangeTimeout = networkChangeTimeout
    }

    public func shouldRetry(error: NetworkError, attempt: Int) -> Bool {
        guard attempt < maxRetries else { return false }
        switch error {
        case .statusCode(let response):
            return response.statusCode == 408
                || response.statusCode == 429
                || (500...599).contains(response.statusCode)
        case .nonHTTPResponse:
            return true
        case .underlying(let error, _):
            return !NetworkError.isCancellation(error)
        case .cancelled:
            return false
        default:
            return false
        }
    }

    public func retryDelay(for attempt: Int) -> TimeInterval {
        let exponent = pow(2.0, Double(max(attempt - 1, 0)))
        let base = min(retryDelay * exponent, maxDelay)
        let jitter = base * jitterRatio
        let range = (-jitter)...(jitter)
        let randomOffset = Double.random(in: range)
        return max(0.0, base + randomOffset)
    }

    public func shouldResetAttempts(afterNetworkChangeFrom oldSnapshot: NetworkSnapshot?, to newSnapshot: NetworkSnapshot?) -> Bool {
        guard let oldSnapshot, let newSnapshot else { return false }
        return oldSnapshot.interfaceTypes != newSnapshot.interfaceTypes
            || oldSnapshot.status != newSnapshot.status
    }
}
