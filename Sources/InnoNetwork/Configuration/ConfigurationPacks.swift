import Foundation

// MARK: - Configuration packs (5.0 forward-compat)
//
// The 5.0 release will replace `NetworkConfiguration.AdvancedBuilder`'s
// flat parameter list with five thematic packs that group related
// knobs. Ship the packs additively in 4.x so adopters can prepare
// composition helpers and migration touch points before the
// primary swap. Each pack is a Sendable struct whose fields are all
// optional with `nil` defaults; calling `apply(to:)` mutates an
// `AdvancedBuilder` in place, leaving fields the pack does not
// carry untouched.
//
// 4.x usage:
//
// ```swift
// NetworkConfiguration.advanced(baseURL: baseURL) { builder in
//     ResiliencePack(retry: ..., circuitBreaker: ...).apply(to: &builder)
//     AuthPack(refreshToken: ..., additionalSigners: [signer]).apply(to: &builder)
// }
// ```
//
// 5.0 usage will accept the packs as named init arguments directly.

/// Groups retry, request coalescing, circuit breaker, idempotency,
/// and response-body buffering policies.
public struct ResiliencePack: Sendable {
    public var retry: RetryPolicy?
    public var coalescing: RequestCoalescingPolicy?
    public var circuitBreaker: CircuitBreakerPolicy?
    public var idempotency: IdempotencyKeyPolicy?
    public var bodyBuffering: ResponseBodyBufferingPolicy?

    public init(
        retry: RetryPolicy? = nil,
        coalescing: RequestCoalescingPolicy? = nil,
        circuitBreaker: CircuitBreakerPolicy? = nil,
        idempotency: IdempotencyKeyPolicy? = nil,
        bodyBuffering: ResponseBodyBufferingPolicy? = nil
    ) {
        self.retry = retry
        self.coalescing = coalescing
        self.circuitBreaker = circuitBreaker
        self.idempotency = idempotency
        self.bodyBuffering = bodyBuffering
    }

    public func apply(to builder: inout NetworkConfiguration.AdvancedBuilder) {
        if let retry { builder.retryPolicy = retry }
        if let coalescing { builder.requestCoalescingPolicy = coalescing }
        if let circuitBreaker { builder.circuitBreakerPolicy = circuitBreaker }
        if let idempotency { builder.idempotencyKeyPolicy = idempotency }
        if let bodyBuffering { builder.responseBodyBufferingPolicy = bodyBuffering }
    }
}

/// Groups refresh-token policy and any signing interceptors.
///
/// Adding a `RequestInterceptor` to `additionalSigners` appends it
/// to the builder's existing `requestInterceptors`; the pack does
/// not replace the chain.
public struct AuthPack: Sendable {
    public var refreshToken: RefreshTokenPolicy?
    public var additionalSigners: [RequestInterceptor]

    public init(
        refreshToken: RefreshTokenPolicy? = nil,
        additionalSigners: [RequestInterceptor] = []
    ) {
        self.refreshToken = refreshToken
        self.additionalSigners = additionalSigners
    }

    public func apply(to builder: inout NetworkConfiguration.AdvancedBuilder) {
        if let refreshToken { builder.refreshTokenPolicy = refreshToken }
        if !additionalSigners.isEmpty {
            builder.requestInterceptors.append(contentsOf: additionalSigners)
        }
    }
}

/// Groups event observers, event delivery policy, and metrics
/// reporters (network and event-pipeline).
public struct ObservabilityPack: Sendable {
    public var eventObservers: [any NetworkEventObserving]
    public var eventDeliveryPolicy: EventDeliveryPolicy?
    public var eventMetricsReporter: (any EventPipelineMetricsReporting)?
    public var networkMonitor: (any NetworkMonitoring)?
    public var metricsReporter: (any NetworkMetricsReporting)?

    public init(
        eventObservers: [any NetworkEventObserving] = [],
        eventDeliveryPolicy: EventDeliveryPolicy? = nil,
        eventMetricsReporter: (any EventPipelineMetricsReporting)? = nil,
        networkMonitor: (any NetworkMonitoring)? = nil,
        metricsReporter: (any NetworkMetricsReporting)? = nil
    ) {
        self.eventObservers = eventObservers
        self.eventDeliveryPolicy = eventDeliveryPolicy
        self.eventMetricsReporter = eventMetricsReporter
        self.networkMonitor = networkMonitor
        self.metricsReporter = metricsReporter
    }

    public func apply(to builder: inout NetworkConfiguration.AdvancedBuilder) {
        if !eventObservers.isEmpty {
            builder.eventObservers.append(contentsOf: eventObservers)
        }
        if let eventDeliveryPolicy { builder.eventDeliveryPolicy = eventDeliveryPolicy }
        if let eventMetricsReporter { builder.eventMetricsReporter = eventMetricsReporter }
        if let networkMonitor { builder.networkMonitor = networkMonitor }
        if let metricsReporter { builder.metricsReporter = metricsReporter }
    }
}

/// Groups response cache policy, the cache backend, and the
/// failure-payload capture toggle.
public struct CachePack: Sendable {
    public var responseCachePolicy: ResponseCachePolicy?
    public var responseCache: (any ResponseCache)?
    public var captureFailurePayload: Bool?

    public init(
        responseCachePolicy: ResponseCachePolicy? = nil,
        responseCache: (any ResponseCache)? = nil,
        captureFailurePayload: Bool? = nil
    ) {
        self.responseCachePolicy = responseCachePolicy
        self.responseCache = responseCache
        self.captureFailurePayload = captureFailurePayload
    }

    public func apply(to builder: inout NetworkConfiguration.AdvancedBuilder) {
        if let responseCachePolicy { builder.responseCachePolicy = responseCachePolicy }
        if let responseCache { builder.responseCache = responseCache }
        if let captureFailurePayload { builder.captureFailurePayload = captureFailurePayload }
    }
}

/// Groups timeout, cache policy, network access toggles, redirect
/// policy, URLSession customization, and the insecure-HTTP escape.
public struct TransportPack: Sendable {
    public var timeout: TimeInterval?
    public var cachePolicy: URLRequest.CachePolicy?
    public var requestPriority: RequestPriority?
    public var allowsCellularAccess: Bool?
    public var allowsExpensiveNetworkAccess: Bool?
    public var allowsConstrainedNetworkAccess: Bool?
    public var redirectPolicy: (any RedirectPolicy)?
    public var allowsInsecureHTTP: Bool?

    public init(
        timeout: TimeInterval? = nil,
        cachePolicy: URLRequest.CachePolicy? = nil,
        requestPriority: RequestPriority? = nil,
        allowsCellularAccess: Bool? = nil,
        allowsExpensiveNetworkAccess: Bool? = nil,
        allowsConstrainedNetworkAccess: Bool? = nil,
        redirectPolicy: (any RedirectPolicy)? = nil,
        allowsInsecureHTTP: Bool? = nil
    ) {
        self.timeout = timeout
        self.cachePolicy = cachePolicy
        self.requestPriority = requestPriority
        self.allowsCellularAccess = allowsCellularAccess
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        self.redirectPolicy = redirectPolicy
        self.allowsInsecureHTTP = allowsInsecureHTTP
    }

    public func apply(to builder: inout NetworkConfiguration.AdvancedBuilder) {
        if let timeout { builder.timeout = timeout }
        if let cachePolicy { builder.cachePolicy = cachePolicy }
        if let requestPriority { builder.requestPriority = requestPriority }
        if let allowsCellularAccess { builder.allowsCellularAccess = allowsCellularAccess }
        if let allowsExpensiveNetworkAccess {
            builder.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        }
        if let allowsConstrainedNetworkAccess {
            builder.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        }
        if let redirectPolicy { builder.redirectPolicy = redirectPolicy }
        if let allowsInsecureHTTP { builder.allowsInsecureHTTP = allowsInsecureHTTP }
    }
}
