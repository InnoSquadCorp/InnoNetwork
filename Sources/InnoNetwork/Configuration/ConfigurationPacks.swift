import Foundation

// MARK: - Configuration packs
//
// `NetworkConfiguration.advanced(baseURL:resilience:auth:observability:cache:transport:)`
// composes the five thematic packs below. Each pack is a Sendable
// struct whose fields are all optional (or empty-array) with `nil`/`[]`
// defaults; the pack mutates the internal builder, leaving fields it
// does not carry untouched.
//
// Usage:
//
// ```swift
// let configuration = NetworkConfiguration.advanced(
//     baseURL: baseURL,
//     resilience: ResiliencePack(retry: retry, circuitBreaker: breaker),
//     auth: AuthPack(refreshToken: refresh, additionalSigners: [signer]),
//     transport: TransportPack(timeout: 30, trustPolicy: .custom(pinning))
// )
// ```

/// Groups retry, request coalescing, circuit breaker, idempotency,
/// response-body buffering, and custom execution policies.
public struct ResiliencePack: Sendable {
    public var retry: RetryPolicy?
    public var coalescing: RequestCoalescingPolicy?
    public var circuitBreaker: CircuitBreakerPolicy?
    public var idempotency: IdempotencyKeyPolicy?
    public var bodyBuffering: ResponseBodyBufferingPolicy?
    /// Custom ``RequestExecutionPolicy`` instances inserted around the
    /// single transport attempt. Replaces the builder slot wholesale;
    /// pass `nil` (the default) to leave the underlying value alone.
    public var customExecutionPolicies: [any RequestExecutionPolicy]?

    public init(
        retry: RetryPolicy? = nil,
        coalescing: RequestCoalescingPolicy? = nil,
        circuitBreaker: CircuitBreakerPolicy? = nil,
        idempotency: IdempotencyKeyPolicy? = nil,
        bodyBuffering: ResponseBodyBufferingPolicy? = nil,
        customExecutionPolicies: [any RequestExecutionPolicy]? = nil
    ) {
        self.retry = retry
        self.coalescing = coalescing
        self.circuitBreaker = circuitBreaker
        self.idempotency = idempotency
        self.bodyBuffering = bodyBuffering
        self.customExecutionPolicies = customExecutionPolicies
    }

    package func apply(to builder: inout NetworkConfiguration.AdvancedBuilder) {
        if let retry { builder.retryPolicy = retry }
        if let coalescing { builder.requestCoalescingPolicy = coalescing }
        if let circuitBreaker { builder.circuitBreakerPolicy = circuitBreaker }
        if let idempotency { builder.idempotencyKeyPolicy = idempotency }
        if let bodyBuffering {
            builder.responseBodyBufferingPolicy = bodyBuffering
            // Keep the deprecated compatibility alias synchronized so the
            // builder does not re-apply the preset's byte ceiling when an
            // adopter explicitly selects an unbounded policy.
            builder.responseBodyLimit = bodyBuffering.maxBytes
        }
        if let customExecutionPolicies { builder.customExecutionPolicies = customExecutionPolicies }
    }
}

/// Groups refresh-token policy and the interceptor chains.
///
/// `additionalRequestInterceptors`, `additionalSigners`,
/// `additionalResponseInterceptors`, and
/// `additionalDecodingInterceptors` are **appended** to the builder's
/// existing chains rather than replacing them, so the pack composes
/// cleanly with `recommendedForProduction(baseURL:)` and other presets
/// that already populate these slots.
public struct AuthPack: Sendable {
    public var refreshToken: RefreshTokenPolicy?
    public var additionalRequestInterceptors: [RequestInterceptor]
    public var additionalSigners: [RequestSigner]
    public var additionalResponseInterceptors: [ResponseInterceptor]
    public var additionalDecodingInterceptors: [DecodingInterceptor]

    public init(
        refreshToken: RefreshTokenPolicy? = nil,
        additionalRequestInterceptors: [RequestInterceptor] = [],
        additionalSigners: [RequestSigner] = [],
        additionalResponseInterceptors: [ResponseInterceptor] = [],
        additionalDecodingInterceptors: [DecodingInterceptor] = []
    ) {
        self.refreshToken = refreshToken
        self.additionalRequestInterceptors = additionalRequestInterceptors
        self.additionalSigners = additionalSigners
        self.additionalResponseInterceptors = additionalResponseInterceptors
        self.additionalDecodingInterceptors = additionalDecodingInterceptors
    }

    package func apply(to builder: inout NetworkConfiguration.AdvancedBuilder) {
        if let refreshToken { builder.refreshTokenPolicy = refreshToken }
        if !additionalRequestInterceptors.isEmpty {
            builder.requestInterceptors.append(contentsOf: additionalRequestInterceptors)
        }
        if !additionalSigners.isEmpty {
            builder.requestSigners.append(contentsOf: additionalSigners)
        }
        if !additionalResponseInterceptors.isEmpty {
            builder.responseInterceptors.append(contentsOf: additionalResponseInterceptors)
        }
        if !additionalDecodingInterceptors.isEmpty {
            builder.decodingInterceptors.append(contentsOf: additionalDecodingInterceptors)
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

    package func apply(to builder: inout NetworkConfiguration.AdvancedBuilder) {
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

    package func apply(to builder: inout NetworkConfiguration.AdvancedBuilder) {
        if let responseCachePolicy { builder.responseCachePolicy = responseCachePolicy }
        if let responseCache { builder.responseCache = responseCache }
        if let captureFailurePayload { builder.captureFailurePayload = captureFailurePayload }
    }
}

/// Groups timeout, cache policy, network access toggles, redirect
/// policy, streaming line byte limits, the insecure-HTTP escape, trust
/// policy, acceptable status codes, and the default `User-Agent` /
/// `Accept-Language` providers.
public struct TransportPack: Sendable {
    public var timeout: TimeInterval?
    public var cachePolicy: URLRequest.CachePolicy?
    public var requestPriority: RequestPriority?
    public var allowsCellularAccess: Bool?
    public var allowsExpensiveNetworkAccess: Bool?
    public var allowsConstrainedNetworkAccess: Bool?
    public var redirectPolicy: (any RedirectPolicy)?
    public var streamingLineByteLimit: Int?
    public var allowsInsecureHTTP: Bool?
    public var trustPolicy: TrustPolicy?
    public var acceptableStatusCodes: Set<Int>?
    public var userAgentProvider: (@Sendable () -> String)?
    public var acceptLanguageProvider: (@Sendable () -> String)?

    public init(
        timeout: TimeInterval? = nil,
        cachePolicy: URLRequest.CachePolicy? = nil,
        requestPriority: RequestPriority? = nil,
        allowsCellularAccess: Bool? = nil,
        allowsExpensiveNetworkAccess: Bool? = nil,
        allowsConstrainedNetworkAccess: Bool? = nil,
        redirectPolicy: (any RedirectPolicy)? = nil,
        streamingLineByteLimit: Int? = nil,
        allowsInsecureHTTP: Bool? = nil,
        trustPolicy: TrustPolicy? = nil,
        acceptableStatusCodes: Set<Int>? = nil,
        userAgentProvider: (@Sendable () -> String)? = nil,
        acceptLanguageProvider: (@Sendable () -> String)? = nil
    ) {
        self.timeout = timeout
        self.cachePolicy = cachePolicy
        self.requestPriority = requestPriority
        self.allowsCellularAccess = allowsCellularAccess
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        self.redirectPolicy = redirectPolicy
        self.streamingLineByteLimit = streamingLineByteLimit
        self.allowsInsecureHTTP = allowsInsecureHTTP
        self.trustPolicy = trustPolicy
        self.acceptableStatusCodes = acceptableStatusCodes
        self.userAgentProvider = userAgentProvider
        self.acceptLanguageProvider = acceptLanguageProvider
    }

    package func apply(to builder: inout NetworkConfiguration.AdvancedBuilder) {
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
        if let streamingLineByteLimit { builder.streamingLineByteLimit = streamingLineByteLimit }
        if let allowsInsecureHTTP { builder.allowsInsecureHTTP = allowsInsecureHTTP }
        if let trustPolicy { builder.trustPolicy = trustPolicy }
        if let acceptableStatusCodes { builder.acceptableStatusCodes = acceptableStatusCodes }
        if let userAgentProvider { builder.userAgentProvider = userAgentProvider }
        if let acceptLanguageProvider { builder.acceptLanguageProvider = acceptLanguageProvider }
    }
}
