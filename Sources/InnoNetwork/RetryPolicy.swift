import Foundation


/// Retry verdict returned by ``RetryPolicy/shouldRetry(error:retryIndex:request:response:)``.
///
/// - `noRetry`: do not retry; surface the error to the caller.
/// - `retry`: retry using the policy's `retryDelay(for:)` value.
/// - `retryAfter(seconds)`: retry, but wait at least the specified
///   number of seconds (e.g. honoring a server's `Retry-After` header).
///   The retry coordinator clamps this against the policy's own delay
///   ceiling so an adversarial server cannot stall a client indefinitely.
public enum RetryDecision: Sendable, Equatable {
    case noRetry
    case retry
    case retryAfter(TimeInterval)
}


public protocol RetryPolicy: Sendable {
    var maxRetries: Int { get }
    /// Maximum total retry count, even if retry count is reset due to network changes.
    var maxTotalRetries: Int { get }
    var retryDelay: TimeInterval { get }
    /// Returns the delay (in seconds) for the given retry index.
    /// `retryIndex` is 0-based and represents actual retry executions.
    func retryDelay(for retryIndex: Int) -> TimeInterval
    /// Legacy boolean retry decision. Kept for source compatibility; new
    /// policies should override
    /// ``shouldRetry(error:retryIndex:request:response:)`` instead so they
    /// can honor `Retry-After` headers and per-request rules.
    func shouldRetry(error: NetworkError, retryIndex: Int) -> Bool
    /// Contextual retry verdict.
    ///
    /// Implementers receive the originating request and the parsed
    /// `HTTPURLResponse` (when one was produced — `nil` for transport
    /// failures that did not reach a status code) and return a
    /// ``RetryDecision``. The default implementation delegates to the
    /// boolean overload for source compatibility, returning
    /// ``RetryDecision/retry`` or ``RetryDecision/noRetry`` accordingly.
    func shouldRetry(
        error: NetworkError,
        retryIndex: Int,
        request: URLRequest?,
        response: HTTPURLResponse?
    ) -> RetryDecision
    var waitsForNetworkChanges: Bool { get }
    var networkChangeTimeout: TimeInterval? { get }
    func shouldResetAttempts(afterNetworkChangeFrom oldSnapshot: NetworkSnapshot?, to newSnapshot: NetworkSnapshot?) -> Bool
}

public extension RetryPolicy {
    var maxTotalRetries: Int { maxRetries }
    var waitsForNetworkChanges: Bool { false }
    var networkChangeTimeout: TimeInterval? { nil }
    func shouldResetAttempts(afterNetworkChangeFrom oldSnapshot: NetworkSnapshot?, to newSnapshot: NetworkSnapshot?) -> Bool {
        false
    }

    func retryDelay(for retryIndex: Int) -> TimeInterval {
        _ = retryIndex
        return retryDelay
    }

    /// Default contextual decision: defers to the legacy boolean overload
    /// so existing implementations keep compiling without changes. Custom
    /// policies that want to honor `Retry-After` headers, branch on HTTP
    /// methods, or inspect response bodies should override this method
    /// directly.
    func shouldRetry(
        error: NetworkError,
        retryIndex: Int,
        request: URLRequest?,
        response: HTTPURLResponse?
    ) -> RetryDecision {
        _ = (request, response)
        return shouldRetry(error: error, retryIndex: retryIndex) ? .retry : .noRetry
    }
}


extension NetworkError {
    /// Returns the originating `URLRequest`, when the error captured one.
    var underlyingRequest: URLRequest? {
        response?.request
    }

    /// Returns the parsed `HTTPURLResponse`, when the error captured one.
    var underlyingHTTPResponse: HTTPURLResponse? {
        response?.response
    }
}

public struct ExponentialBackoffRetryPolicy: RetryPolicy {
    public let maxRetries: Int
    public let maxTotalRetries: Int
    public let retryDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let jitterRatio: Double
    public let waitsForNetworkChanges: Bool
    public let networkChangeTimeout: TimeInterval?

    /// - Parameters:
    ///   - maxRetries: Maximum number of retries.
    ///   - maxTotalRetries: Maximum total retry count even if the counter is reset.
    ///   - retryDelay: Base retry delay in seconds.
    ///   - maxDelay: Maximum delay for exponential backoff in seconds.
    ///   - jitterRatio: Jitter ratio applied to the delay (e.g., 0.2 means ±20%). Must be non-negative; negative jitter results are clamped to 0.
    ///   - waitsForNetworkChanges: Whether to wait for network changes before retrying.
    ///   - networkChangeTimeout: Timeout for waiting for network changes. If `nil`, waits indefinitely.
    public init(
        maxRetries: Int = 3,
        maxTotalRetries: Int? = nil,
        retryDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        jitterRatio: Double = 0.2,
        waitsForNetworkChanges: Bool = false,
        networkChangeTimeout: TimeInterval? = 10.0
    ) {
        self.maxRetries = maxRetries
        self.maxTotalRetries = maxTotalRetries ?? maxRetries
        self.retryDelay = retryDelay
        self.maxDelay = maxDelay
        self.jitterRatio = jitterRatio
        self.waitsForNetworkChanges = waitsForNetworkChanges
        self.networkChangeTimeout = networkChangeTimeout
    }

    public func shouldRetry(error: NetworkError, retryIndex: Int) -> Bool {
        guard retryIndex < maxRetries else { return false }
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

    public func retryDelay(for retryIndex: Int) -> TimeInterval {
        let exponent = pow(2.0, Double(max(retryIndex, 0)))
        let base = min(retryDelay * exponent, maxDelay)
        let jitter = abs(base * jitterRatio)
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
