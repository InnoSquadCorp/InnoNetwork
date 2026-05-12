import Foundation

/// Retry verdict returned by ``RetryPolicy/shouldRetry(error:retryIndex:request:response:)``.
///
/// - `noRetry`: do not retry; surface the error to the caller.
/// - `retry`: retry using the policy's `retryDelay(for:)` value.
/// - `retryAfter(seconds)`: retry, preferring the specified
///   number of seconds (e.g. honoring a server's `Retry-After` header).
///   The retry coordinator never sleeps less than the policy's computed
///   `retryDelay(for:)` value, and clamps the server hint to
///   ``RetryPolicy/maxRetryAfterDelay`` when the policy provides one.
public enum RetryDecision: Sendable, Equatable {
    case noRetry
    case retry
    case retryAfter(TimeInterval)
}


public protocol RetryPolicy: Sendable {
    var maxRetries: Int { get }
    /// Absolute retry budget for one logical request.
    ///
    /// ``maxRetries`` may reset when a policy observes a meaningful network
    /// change, but `maxTotalRetries` never resets. Use it as a session-level
    /// safety cap so network flapping cannot turn one request into an
    /// unbounded retry loop.
    var maxTotalRetries: Int { get }
    var retryDelay: TimeInterval { get }
    /// Optional absolute ceiling for `Retry-After` waits.
    ///
    /// When `nil`, the coordinator honors server hints after applying the
    /// policy's computed retry delay floor. When non-`nil`, the coordinator
    /// caps server hints at this value but will not reduce the wait below
    /// `retryDelay(for:)`.
    var maxRetryAfterDelay: TimeInterval? { get }
    /// Returns the delay (in seconds) for the given retry index.
    /// `retryIndex` is 0-based and represents actual retry executions.
    func retryDelay(for retryIndex: Int) -> TimeInterval
    /// Contextual retry verdict.
    ///
    /// Implementers receive the originating request and the parsed
    /// `HTTPURLResponse` (when one was produced — `nil` for transport
    /// failures that did not reach a status code) and return a
    /// ``RetryDecision``. This is the sole retry-decision entry point — the
    /// 4.0 release removed the legacy boolean overload that earlier versions
    /// kept for source compatibility.
    func shouldRetry(
        error: NetworkError,
        retryIndex: Int,
        request: URLRequest?,
        response: HTTPURLResponse?
    ) -> RetryDecision
    var waitsForNetworkChanges: Bool { get }
    var networkChangeTimeout: TimeInterval? { get }
    /// Idempotency policy consulted by the retry coordinator's safety net
    /// for non-idempotent timeouts. The default impl returns
    /// ``RetryIdempotencyPolicy/safeMethodsAndIdempotencyKey`` so custom
    /// policies inherit the conservative behaviour automatically; override
    /// to expose ``RetryIdempotencyPolicy/methodAgnostic`` when the caller
    /// owns duplicate-write protection above InnoNetwork.
    var idempotencyPolicy: RetryIdempotencyPolicy { get }
    func shouldResetAttempts(afterNetworkChangeFrom oldSnapshot: NetworkSnapshot?, to newSnapshot: NetworkSnapshot?)
        -> Bool
}


public struct RetryIdempotencyPolicy: Sendable, Equatable {
    public let safeMethods: Set<String>
    public let idempotencyHeaderName: String
    public let retriesUnsafeMethodsWithIdempotencyKey: Bool
    public let retriesAllMethods: Bool

    /// Retries safe methods (`GET`, `HEAD`, `OPTIONS`, `TRACE`) and unsafe
    /// methods only when an idempotency key header is present.
    public static let safeMethodsAndIdempotencyKey = RetryIdempotencyPolicy()

    /// Preserves pre-4.x method-agnostic retry behaviour for consumers that
    /// already own duplicate-write protection above InnoNetwork.
    public static let methodAgnostic = RetryIdempotencyPolicy(retriesAllMethods: true)

    public init(
        safeMethods: Set<String> = ["GET", "HEAD", "OPTIONS", "TRACE"],
        idempotencyHeaderName: String = "Idempotency-Key",
        retriesUnsafeMethodsWithIdempotencyKey: Bool = true,
        retriesAllMethods: Bool = false
    ) {
        self.safeMethods = Set(safeMethods.map { $0.uppercased() })
        self.idempotencyHeaderName = idempotencyHeaderName
        self.retriesUnsafeMethodsWithIdempotencyKey = retriesUnsafeMethodsWithIdempotencyKey
        self.retriesAllMethods = retriesAllMethods
    }

    public func allowsRetry(for request: URLRequest?) -> Bool {
        guard !retriesAllMethods else { return true }
        guard let request else { return false }
        let method = (request.httpMethod ?? "GET").uppercased()
        if safeMethods.contains(method) {
            return true
        }
        guard retriesUnsafeMethodsWithIdempotencyKey else { return false }
        return request.value(forHTTPHeaderField: idempotencyHeaderName)?.isEmpty == false
    }
}

public extension RetryPolicy {
    var maxTotalRetries: Int { maxRetries }
    var maxRetryAfterDelay: TimeInterval? { nil }
    var waitsForNetworkChanges: Bool { false }
    var networkChangeTimeout: TimeInterval? { nil }
    var idempotencyPolicy: RetryIdempotencyPolicy { .safeMethodsAndIdempotencyKey }
    func shouldResetAttempts(afterNetworkChangeFrom oldSnapshot: NetworkSnapshot?, to newSnapshot: NetworkSnapshot?)
        -> Bool
    {
        false
    }

    func retryDelay(for retryIndex: Int) -> TimeInterval {
        _ = retryIndex
        return retryDelay
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
    public let maxRetryAfterDelay: TimeInterval?
    public let maxDelay: TimeInterval
    public let jitterRatio: Double
    public let waitsForNetworkChanges: Bool
    public let networkChangeTimeout: TimeInterval?
    public let idempotencyPolicy: RetryIdempotencyPolicy

    /// - Parameters:
    ///   - maxRetries: Maximum number of retries.
    ///   - maxTotalRetries: Maximum total retry count even if the counter is reset.
    ///   - retryDelay: Base retry delay in seconds.
    ///   - maxRetryAfterDelay: Maximum delay honored from a `Retry-After`
    ///     header. Pass `nil` to honor server hints without an absolute cap.
    ///   - maxDelay: Maximum delay for exponential backoff in seconds.
    ///   - jitterRatio: Jitter ratio applied to the delay (e.g., 0.2 means ±20%). Must be non-negative; negative jitter results are clamped to 0.
    ///   - waitsForNetworkChanges: Whether to wait for network changes before retrying.
    ///   - networkChangeTimeout: Timeout for waiting for network changes. If `nil`, waits indefinitely.
    ///   - idempotencyPolicy: Controls which HTTP methods the built-in policy
    ///     can retry. Defaults to safe methods plus unsafe methods that carry
    ///     `Idempotency-Key`.
    public init(
        maxRetries: Int = 3,
        maxTotalRetries: Int? = nil,
        retryDelay: TimeInterval = 1.0,
        maxRetryAfterDelay: TimeInterval? = 60.0,
        maxDelay: TimeInterval = 30.0,
        jitterRatio: Double = 0.2,
        waitsForNetworkChanges: Bool = false,
        networkChangeTimeout: TimeInterval? = 10.0,
        idempotencyPolicy: RetryIdempotencyPolicy = .safeMethodsAndIdempotencyKey
    ) {
        self.maxRetries = maxRetries
        self.maxTotalRetries = maxTotalRetries ?? maxRetries
        self.retryDelay = retryDelay
        self.maxRetryAfterDelay = maxRetryAfterDelay.map { max(0, $0) }
        self.maxDelay = maxDelay
        self.jitterRatio = jitterRatio
        self.waitsForNetworkChanges = waitsForNetworkChanges
        self.networkChangeTimeout = networkChangeTimeout
        self.idempotencyPolicy = idempotencyPolicy
    }

    private func isRetryableErrorClass(_ error: NetworkError, retryIndex: Int) -> Bool {
        guard retryIndex < maxRetries else { return false }
        switch error {
        case .statusCode(let response):
            return response.statusCode == 408
                || response.statusCode == 429
                || (500...599).contains(response.statusCode)
        case .underlying(let error, _):
            return !NetworkError.isCancellation(error)
        case .reachability:
            // Connectivity-class URLErrors (`notConnectedToInternet`,
            // `dnsLookupFailed`, `cannotFindHost`, `networkConnectionLost`)
            // were `.underlying` before this branch and retried by default;
            // preserve that contract after the typed-throws refactor. The
            // outer policy still honours `waitsForNetworkChanges` so an
            // offline device does not burn its retry budget against a
            // closed pipe.
            return true
        case .timeout:
            // Request and connection timeouts are typically transient.
            return true
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

    public func shouldResetAttempts(
        afterNetworkChangeFrom oldSnapshot: NetworkSnapshot?, to newSnapshot: NetworkSnapshot?
    ) -> Bool {
        guard let oldSnapshot, let newSnapshot else { return false }
        return oldSnapshot.interfaceTypes != newSnapshot.interfaceTypes
            || oldSnapshot.status != newSnapshot.status
    }

    /// Contextual retry decision that honors `Retry-After` on `429`, `503`,
    /// and `3xx` responses per RFC 9110 §10.2.3 (delta-seconds form) and
    /// RFC 9110 §5.6.7 (HTTP-date form).
    ///
    /// Returns `.retry` (no server hint) when no `Retry-After` header is
    /// present or the value cannot be parsed; the coordinator then picks
    /// the policy's own jittered delay.
    public func shouldRetry(
        error: NetworkError,
        retryIndex: Int,
        request: URLRequest?,
        response: HTTPURLResponse?
    ) -> RetryDecision {
        guard idempotencyPolicy.allowsRetry(for: request) else { return .noRetry }
        // Cap parsed Retry-After values so a malicious or buggy server
        // cannot pin a retry attempt to a year-scale delay; the policy's
        // own `maxRetryAfterDelay` (or `maxDelay` when unset) is the
        // ceiling.
        let cap = maxRetryAfterDelay ?? maxDelay

        // 3xx responses are not retryable on their own, but RFC 9110 §10.2.3
        // lists Retry-After as applicable to 3xx — handle that branch
        // explicitly so callers that surface a non-followed 3xx (e.g. a
        // redirect policy that rejected the target) can honor the server
        // hint. This must run before `isRetryableErrorClass`, which excludes
        // 3xx from the general retryable set.
        if retryIndex < maxRetries,
            let response,
            (300...399).contains(response.statusCode),
            Self.honorsRetryAfter(statusCode: response.statusCode),
            let header = response.value(forHTTPHeaderField: "Retry-After"),
            let seconds = Self.parseRetryAfter(header, maxSeconds: cap)
        {
            return .retryAfter(seconds)
        }

        guard isRetryableErrorClass(error, retryIndex: retryIndex) else { return .noRetry }
        guard let response,
            Self.honorsRetryAfter(statusCode: response.statusCode),
            let header = response.value(forHTTPHeaderField: "Retry-After")
        else {
            return .retry
        }
        if let seconds = Self.parseRetryAfter(header, maxSeconds: cap) {
            return .retryAfter(seconds)
        }
        return .retry
    }

    /// RFC 9110 §10.2.3 lists `Retry-After` as applicable to `503`, `429`,
    /// and the `3xx` redirect class. URLSession typically follows
    /// redirects automatically, but custom redirect policies can surface
    /// the original response — honor the hint in that case too.
    private static func honorsRetryAfter(statusCode: Int) -> Bool {
        statusCode == 429 || statusCode == 503 || (300...399).contains(statusCode)
    }

    /// Parses an RFC 9110 `Retry-After` header value into a non-negative
    /// `TimeInterval`. Returns `nil` for malformed input or HTTP-dates in
    /// the past so the coordinator falls back to the computed backoff. The
    /// returned value is clamped to `maxSeconds` to prevent absurd waits
    /// from `Retry-After: 9223372036854775807`-style header values.
    static func parseRetryAfter(_ value: String, now: Date = Date(), maxSeconds: TimeInterval = .infinity)
        -> TimeInterval?
    {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Int(trimmed), seconds >= 0 {
            return min(TimeInterval(seconds), maxSeconds)
        }
        if let date = HTTPDateParser.parse(trimmed) {
            let delta = date.timeIntervalSince(now)
            guard delta > 0 else { return nil }
            return min(delta, maxSeconds)
        }
        return nil
    }
}
