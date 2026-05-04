import Foundation

public struct NetworkConfiguration: Sendable {
    /// The default range of HTTP status codes treated as successful responses.
    /// `2xx` per RFC 9110 §15.3.
    public static let defaultAcceptableStatusCodes: Set<Int> = Set(200..<300)

    package enum Presets {
        static func safeDefaults(baseURL: URL) -> NetworkConfiguration {
            NetworkConfiguration(
                baseURL: baseURL,
                timeout: 30.0,
                cachePolicy: .useProtocolCachePolicy,
                requestPriority: .normal,
                allowsCellularAccess: true,
                allowsExpensiveNetworkAccess: true,
                allowsConstrainedNetworkAccess: true,
                retryPolicy: nil,
                networkMonitor: NetworkMonitor.shared,
                metricsReporter: nil,
                trustPolicy: .systemDefault,
                eventObservers: [],
                eventDeliveryPolicy: .default,
                eventMetricsReporter: nil,
                acceptableStatusCodes: NetworkConfiguration.defaultAcceptableStatusCodes,
                requestInterceptors: [],
                responseInterceptors: [],
                customExecutionPolicies: [],
                idempotencyKeyPolicy: .disabled,
                responseBodyBufferingPolicy: .streaming(),
                redirectPolicy: DefaultRedirectPolicy()
            )
        }

        static func advancedTuning(baseURL: URL) -> NetworkConfiguration {
            NetworkConfiguration(
                baseURL: baseURL,
                timeout: 60.0,
                cachePolicy: .reloadIgnoringLocalCacheData,
                requestPriority: .normal,
                allowsCellularAccess: true,
                allowsExpensiveNetworkAccess: true,
                allowsConstrainedNetworkAccess: true,
                retryPolicy: nil,
                networkMonitor: NetworkMonitor.shared,
                metricsReporter: nil,
                trustPolicy: .systemDefault,
                eventObservers: [],
                eventDeliveryPolicy: EventDeliveryPolicy(
                    maxBufferedEventsPerPartition: 512,
                    maxBufferedEventsPerConsumer: 512,
                    overflowPolicy: .dropOldest
                ),
                eventMetricsReporter: nil,
                acceptableStatusCodes: NetworkConfiguration.defaultAcceptableStatusCodes,
                requestInterceptors: [],
                responseInterceptors: [],
                customExecutionPolicies: [],
                idempotencyKeyPolicy: .disabled,
                responseBodyBufferingPolicy: .streaming(),
                redirectPolicy: DefaultRedirectPolicy()
            )
        }
    }

    public let baseURL: URL
    public let timeout: TimeInterval
    public let cachePolicy: URLRequest.CachePolicy
    public let requestPriority: RequestPriority
    public let allowsCellularAccess: Bool
    public let allowsExpensiveNetworkAccess: Bool
    public let allowsConstrainedNetworkAccess: Bool
    public let retryPolicy: RetryPolicy?
    public let networkMonitor: (any NetworkMonitoring)?
    public let metricsReporter: (any NetworkMetricsReporting)?
    public let trustPolicy: TrustPolicy
    public let eventObservers: [any NetworkEventObserving]
    public let eventDeliveryPolicy: EventDeliveryPolicy
    public let eventMetricsReporter: (any EventPipelineMetricsReporting)?
    /// HTTP status codes that the request executor treats as successful.
    /// Responses with a status code outside this set throw
    /// ``NetworkError/statusCode(_:)``. Defaults to ``defaultAcceptableStatusCodes``
    /// (`200..<300`); override to allow values like `304` or `205` to flow
    /// through to consumer code without error mapping.
    public let acceptableStatusCodes: Set<Int>
    /// Request interceptors applied to **every** request dispatched through
    /// this client, before any per-``APIDefinition`` interceptors. Use this
    /// slot for cross-cutting concerns (Bearer auth, distributed-tracing
    /// headers, request IDs) so each ``APIDefinition`` does not have to
    /// re-declare them.
    public let requestInterceptors: [RequestInterceptor]
    /// Response interceptors applied to **every** response, after any
    /// per-``APIDefinition`` interceptors. The order is intentionally an
    /// onion: the request chain runs outer→inner (config first), and the
    /// response chain unwinds inner→outer (config last) so a session-level
    /// interceptor can observe the same response shape its peer would have
    /// produced under a per-endpoint setup.
    public let responseInterceptors: [ResponseInterceptor]
    /// Decoding interceptors applied around the response decode boundary
    /// for **every** request. Hooks fire after all response interceptors
    /// have settled, immediately before and after the configured decoder
    /// runs. Use them for envelope unwrapping, payload sanitization,
    /// decode metrics, or typed-value normalization. See
    /// ``DecodingInterceptor`` for ordering and failure semantics.
    public let decodingInterceptors: [DecodingInterceptor]
    /// Optional token refresh policy. When configured, the client applies the
    /// current token before transport, refreshes once on matching auth status
    /// codes, and replays the fully adapted request at most one time.
    public let refreshTokenPolicy: RefreshTokenPolicy?
    /// Optional raw-transport coalescing policy. Disabled by default.
    public let requestCoalescingPolicy: RequestCoalescingPolicy
    /// Optional response cache policy. Disabled by default.
    public let responseCachePolicy: ResponseCachePolicy
    /// Cache storage used when ``responseCachePolicy`` is enabled.
    public let responseCache: (any ResponseCache)?
    /// Optional per-host circuit breaker policy. Disabled by default.
    public let circuitBreakerPolicy: CircuitBreakerPolicy?
    /// Custom public execution policies wrapped around each raw transport
    /// attempt after request adaptation/auth application and before response
    /// interceptors, status validation, cache writes, and decoding.
    public let customExecutionPolicies: [any RequestExecutionPolicy]
    /// Optional policy that attaches one stable idempotency key to every
    /// retry attempt for the same logical request.
    public let idempotencyKeyPolicy: IdempotencyKeyPolicy

    /// Produces the default `User-Agent` value at request-build time.
    ///
    /// The provider is evaluated for each request when the endpoint still
    /// carries the library default `User-Agent`, allowing tests and apps with
    /// custom bundle metadata to avoid a process-start snapshot.
    public let userAgentProvider: @Sendable () -> String

    /// Produces the default `Accept-Language` value at request-build time.
    ///
    /// The provider is evaluated for each request when the endpoint still
    /// carries the library default `Accept-Language`, so locale changes can
    /// be reflected without rebuilding endpoint types.
    public let acceptLanguageProvider: @Sendable () -> String

    /// When `false` (default), response bodies attached to ``NetworkError``
    /// cases (`decoding`, `statusCode`, and `underlying` when present) are
    /// zeroed out before the error is logged or surfaced
    /// to consumers, so PII in failure payloads cannot accidentally leak
    /// into crash logs, analytics, or error reporting. Status code, headers,
    /// and the original `URLRequest` are preserved.
    ///
    /// Set this to `true` only in diagnostic configurations where capturing
    /// the failing response body is worth the privacy trade-off.
    public let captureFailurePayload: Bool

    /// Inline response body collection policy. The 4.0.0 default is
    /// ``ResponseBodyBufferingPolicy/streaming(maxBytes:)`` so real
    /// `URLSession` transports collect `bytes(for:)` with an optional memory
    /// bound before cache writes or decoder handoff. Test doubles that only
    /// implement `data(for:)` fall back to buffered transport.
    public let responseBodyBufferingPolicy: ResponseBodyBufferingPolicy

    /// Compatibility alias for the optional maximum body size in
    /// ``responseBodyBufferingPolicy``. New code should set
    /// ``responseBodyBufferingPolicy`` directly.
    public let responseBodyLimit: Int64?

    /// Decides how the client reacts to HTTP redirects (3xx + `Location`).
    /// Defaults to ``DefaultRedirectPolicy``, which strips
    /// `Authorization`, `Cookie`, and `Proxy-Authorization` on cross-origin
    /// hops per RFC 9110 §15.4.4.
    public let redirectPolicy: any RedirectPolicy

    /// When `false` (default), a `baseURL` with `http://` scheme is rejected
    /// at request-build time with ``NetworkError/invalidBaseURL(_:)``. App
    /// Transport Security blocks plain-HTTP traffic at the Apple platform
    /// level for App Store submissions; this flag adds a defense-in-depth
    /// guard for callers that may have ATS exemptions or run in macOS/CLI
    /// targets without ATS enforcement. Set to `true` only when the
    /// non-encrypted endpoint is intentional (loopback, private LAN, opt-in
    /// staging).
    public let allowsInsecureHTTP: Bool

    /// Optional escape hatch for callers that need to customize the
    /// `URLSessionConfiguration` (proxy/HTTP2 tuning, connection pooling,
    /// `httpAdditionalHeaders`, TLS minimum version, etc.) when materializing
    /// a `URLSession` for this configuration. The closure receives a fresh
    /// `URLSessionConfiguration.default`-derived instance and must return a
    /// configuration the caller is comfortable shipping. Because
    /// `URLSession.shared` cannot honor this hook, `DefaultNetworkClient`
    /// rejects the combination of a non-nil override and the default shared
    /// session. Consumers must wire this through
    /// ``makeURLSessionConfiguration()`` and pass the resulting `URLSession`
    /// explicitly.
    public let urlSessionConfigurationOverride: (@Sendable (URLSessionConfiguration) -> URLSessionConfiguration)?

    /// Build a `URLSessionConfiguration` derived from `URLSessionConfiguration.default`,
    /// applying ``urlSessionConfigurationOverride`` when set. Provided as a
    /// convenience for callers that construct their own `URLSession` and want
    /// the override hook honored without re-implementing the wiring.
    public func makeURLSessionConfiguration() -> URLSessionConfiguration {
        let base = URLSessionConfiguration.default
        guard let override = urlSessionConfigurationOverride else { return base }
        return override(base)
    }

    public struct AdvancedBuilder: Sendable {
        public var baseURL: URL
        public var timeout: TimeInterval
        public var cachePolicy: URLRequest.CachePolicy
        public var requestPriority: RequestPriority
        public var allowsCellularAccess: Bool
        public var allowsExpensiveNetworkAccess: Bool
        public var allowsConstrainedNetworkAccess: Bool
        public var retryPolicy: RetryPolicy?
        public var networkMonitor: (any NetworkMonitoring)?
        public var metricsReporter: (any NetworkMetricsReporting)?
        public var trustPolicy: TrustPolicy
        public var eventObservers: [any NetworkEventObserving]
        public var eventDeliveryPolicy: EventDeliveryPolicy
        public var eventMetricsReporter: (any EventPipelineMetricsReporting)?
        public var acceptableStatusCodes: Set<Int>
        public var requestInterceptors: [RequestInterceptor]
        public var responseInterceptors: [ResponseInterceptor]
        public var decodingInterceptors: [DecodingInterceptor]
        public var refreshTokenPolicy: RefreshTokenPolicy?
        public var requestCoalescingPolicy: RequestCoalescingPolicy
        public var responseCachePolicy: ResponseCachePolicy
        public var responseCache: (any ResponseCache)?
        public var circuitBreakerPolicy: CircuitBreakerPolicy?
        /// Custom ``RequestExecutionPolicy`` instances inserted around the
        /// single transport attempt. Policies execute in array order — the
        /// first element wraps the next policy and ultimately the transport
        /// call for that attempt. Cache lookup/substitution, auth-refresh
        /// replay, and outer retry scheduling remain outside this chain. See
        /// ``RequestExecutionNext/execute(_:)`` for the per-policy calling
        /// contract.
        public var customExecutionPolicies: [any RequestExecutionPolicy]
        /// See ``NetworkConfiguration/idempotencyKeyPolicy``.
        public var idempotencyKeyPolicy: IdempotencyKeyPolicy
        /// See ``NetworkConfiguration/userAgentProvider``.
        public var userAgentProvider: @Sendable () -> String
        /// See ``NetworkConfiguration/acceptLanguageProvider``.
        public var acceptLanguageProvider: @Sendable () -> String
        public var captureFailurePayload: Bool
        /// Whether request bodies are streamed or buffered before decoding.
        /// `URLSession` transports collect `bytes(for:)` with an optional
        /// memory bound before cache writes or decoder handoff. Test doubles
        /// that only implement `data(for:)` fall back to buffered transport.
        public var responseBodyBufferingPolicy: ResponseBodyBufferingPolicy
        /// Compatibility alias for the optional maximum body size in
        /// ``responseBodyBufferingPolicy``. New code should set
        /// ``responseBodyBufferingPolicy`` directly.
        public var responseBodyLimit: Int64?
        /// See ``NetworkConfiguration/redirectPolicy``.
        public var redirectPolicy: any RedirectPolicy
        /// See ``NetworkConfiguration/allowsInsecureHTTP``.
        public var allowsInsecureHTTP: Bool
        /// See ``NetworkConfiguration/urlSessionConfigurationOverride``.
        public var urlSessionConfigurationOverride: (@Sendable (URLSessionConfiguration) -> URLSessionConfiguration)?

        fileprivate init(preset: NetworkConfiguration) {
            self.baseURL = preset.baseURL
            self.timeout = preset.timeout
            self.cachePolicy = preset.cachePolicy
            self.requestPriority = preset.requestPriority
            self.allowsCellularAccess = preset.allowsCellularAccess
            self.allowsExpensiveNetworkAccess = preset.allowsExpensiveNetworkAccess
            self.allowsConstrainedNetworkAccess = preset.allowsConstrainedNetworkAccess
            self.retryPolicy = preset.retryPolicy
            self.networkMonitor = preset.networkMonitor
            self.metricsReporter = preset.metricsReporter
            self.trustPolicy = preset.trustPolicy
            self.eventObservers = preset.eventObservers
            self.eventDeliveryPolicy = preset.eventDeliveryPolicy
            self.eventMetricsReporter = preset.eventMetricsReporter
            self.acceptableStatusCodes = preset.acceptableStatusCodes
            self.requestInterceptors = preset.requestInterceptors
            self.responseInterceptors = preset.responseInterceptors
            self.decodingInterceptors = preset.decodingInterceptors
            self.refreshTokenPolicy = preset.refreshTokenPolicy
            self.requestCoalescingPolicy = preset.requestCoalescingPolicy
            self.responseCachePolicy = preset.responseCachePolicy
            self.responseCache = preset.responseCache
            self.circuitBreakerPolicy = preset.circuitBreakerPolicy
            self.customExecutionPolicies = preset.customExecutionPolicies
            self.idempotencyKeyPolicy = preset.idempotencyKeyPolicy
            self.userAgentProvider = preset.userAgentProvider
            self.acceptLanguageProvider = preset.acceptLanguageProvider
            self.captureFailurePayload = preset.captureFailurePayload
            self.responseBodyBufferingPolicy = preset.responseBodyBufferingPolicy
            self.responseBodyLimit = preset.responseBodyLimit
            self.redirectPolicy = preset.redirectPolicy
            self.allowsInsecureHTTP = preset.allowsInsecureHTTP
            self.urlSessionConfigurationOverride = preset.urlSessionConfigurationOverride
        }

        fileprivate func build() -> NetworkConfiguration {
            NetworkConfiguration(
                baseURL: baseURL,
                timeout: timeout,
                cachePolicy: cachePolicy,
                requestPriority: requestPriority,
                allowsCellularAccess: allowsCellularAccess,
                allowsExpensiveNetworkAccess: allowsExpensiveNetworkAccess,
                allowsConstrainedNetworkAccess: allowsConstrainedNetworkAccess,
                retryPolicy: retryPolicy,
                networkMonitor: networkMonitor,
                metricsReporter: metricsReporter,
                trustPolicy: trustPolicy,
                eventObservers: eventObservers,
                eventDeliveryPolicy: eventDeliveryPolicy,
                eventMetricsReporter: eventMetricsReporter,
                acceptableStatusCodes: acceptableStatusCodes,
                requestInterceptors: requestInterceptors,
                responseInterceptors: responseInterceptors,
                decodingInterceptors: decodingInterceptors,
                refreshTokenPolicy: refreshTokenPolicy,
                requestCoalescingPolicy: requestCoalescingPolicy,
                responseCachePolicy: responseCachePolicy,
                responseCache: responseCache,
                circuitBreakerPolicy: circuitBreakerPolicy,
                customExecutionPolicies: customExecutionPolicies,
                idempotencyKeyPolicy: idempotencyKeyPolicy,
                userAgentProvider: userAgentProvider,
                acceptLanguageProvider: acceptLanguageProvider,
                captureFailurePayload: captureFailurePayload,
                responseBodyBufferingPolicy: responseBodyBufferingPolicy,
                responseBodyLimit: responseBodyLimit,
                urlSessionConfigurationOverride: urlSessionConfigurationOverride,
                redirectPolicy: redirectPolicy,
                allowsInsecureHTTP: allowsInsecureHTTP
            )
        }
    }

    public static func safeDefaults(baseURL: URL) -> NetworkConfiguration {
        Presets.safeDefaults(baseURL: baseURL)
    }

    /// Production-oriented preset for apps that want conservative resilience
    /// defaults without hand-wiring every policy.
    ///
    /// The preset keeps caching, auth refresh, and custom execution policies
    /// opt-in, but enables bounded retries for transient failures, a per-host
    /// circuit breaker, automatic idempotency keys for unsafe methods, and
    /// streaming response body collection.
    public static func recommendedForProduction(baseURL: URL) -> NetworkConfiguration {
        NetworkConfiguration.advanced(baseURL: baseURL) { builder in
            builder.timeout = 30
            builder.cachePolicy = .useProtocolCachePolicy
            builder.retryPolicy = ExponentialBackoffRetryPolicy(
                maxRetries: 2,
                maxTotalRetries: 3,
                retryDelay: 0.5,
                maxRetryAfterDelay: 30,
                maxDelay: 8,
                jitterRatio: 0.2,
                waitsForNetworkChanges: true,
                networkChangeTimeout: 10
            )
            builder.circuitBreakerPolicy = CircuitBreakerPolicy(
                failureThreshold: 5,
                windowSize: 10,
                resetAfter: .seconds(30),
                maxResetAfter: .seconds(300)
            )
            builder.idempotencyKeyPolicy = .automaticForUnsafeMethods()
            builder.responseBodyBufferingPolicy = .streaming()
        }
    }

    public static func advanced(
        baseURL: URL,
        _ configure: (inout AdvancedBuilder) -> Void
    ) -> NetworkConfiguration {
        var builder = AdvancedBuilder(preset: Presets.advancedTuning(baseURL: baseURL))
        configure(&builder)
        return builder.build()
    }

    public init(
        baseURL: URL,
        timeout: TimeInterval = 30.0,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        requestPriority: RequestPriority = .normal,
        allowsCellularAccess: Bool = true,
        allowsExpensiveNetworkAccess: Bool = true,
        allowsConstrainedNetworkAccess: Bool = true,
        retryPolicy: RetryPolicy? = nil,
        networkMonitor: (any NetworkMonitoring)? = NetworkMonitor.shared,
        metricsReporter: (any NetworkMetricsReporting)? = nil,
        trustPolicy: TrustPolicy = .systemDefault,
        eventObservers: [any NetworkEventObserving] = [],
        eventDeliveryPolicy: EventDeliveryPolicy = .default,
        eventMetricsReporter: (any EventPipelineMetricsReporting)? = nil,
        acceptableStatusCodes: Set<Int> = NetworkConfiguration.defaultAcceptableStatusCodes,
        requestInterceptors: [RequestInterceptor] = [],
        responseInterceptors: [ResponseInterceptor] = [],
        decodingInterceptors: [DecodingInterceptor] = [],
        refreshTokenPolicy: RefreshTokenPolicy? = nil,
        requestCoalescingPolicy: RequestCoalescingPolicy = .disabled,
        responseCachePolicy: ResponseCachePolicy = .disabled,
        responseCache: (any ResponseCache)? = nil,
        circuitBreakerPolicy: CircuitBreakerPolicy? = nil,
        customExecutionPolicies: [any RequestExecutionPolicy] = [],
        idempotencyKeyPolicy: IdempotencyKeyPolicy = .disabled,
        userAgentProvider: @escaping @Sendable () -> String = { HTTPHeader.defaultUserAgent.value },
        acceptLanguageProvider: @escaping @Sendable () -> String = { HTTPHeader.defaultAcceptLanguage.value },
        captureFailurePayload: Bool = false,
        responseBodyBufferingPolicy: ResponseBodyBufferingPolicy = .streaming(),
        responseBodyLimit: Int64? = nil,
        urlSessionConfigurationOverride: (@Sendable (URLSessionConfiguration) -> URLSessionConfiguration)? = nil,
        redirectPolicy: any RedirectPolicy = DefaultRedirectPolicy(),
        allowsInsecureHTTP: Bool = false
    ) {
        let resolvedBufferingPolicy =
            responseBodyLimit.map { responseBodyBufferingPolicy.replacingMaxBytes($0) }
            ?? responseBodyBufferingPolicy
        self.baseURL = baseURL
        self.timeout = timeout
        self.cachePolicy = cachePolicy
        self.requestPriority = requestPriority
        self.allowsCellularAccess = allowsCellularAccess
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        self.retryPolicy = retryPolicy
        self.networkMonitor = networkMonitor
        self.metricsReporter = metricsReporter
        self.trustPolicy = trustPolicy
        self.eventObservers = eventObservers
        self.eventDeliveryPolicy = eventDeliveryPolicy
        self.eventMetricsReporter = eventMetricsReporter
        self.acceptableStatusCodes = acceptableStatusCodes
        self.requestInterceptors = requestInterceptors
        self.responseInterceptors = responseInterceptors
        self.decodingInterceptors = decodingInterceptors
        self.refreshTokenPolicy = refreshTokenPolicy
        self.requestCoalescingPolicy = requestCoalescingPolicy
        self.responseCachePolicy = responseCachePolicy
        self.responseCache = responseCache
        self.circuitBreakerPolicy = circuitBreakerPolicy
        self.customExecutionPolicies = customExecutionPolicies
        self.idempotencyKeyPolicy = idempotencyKeyPolicy
        self.userAgentProvider = userAgentProvider
        self.acceptLanguageProvider = acceptLanguageProvider
        self.captureFailurePayload = captureFailurePayload
        self.responseBodyBufferingPolicy = resolvedBufferingPolicy
        self.responseBodyLimit = resolvedBufferingPolicy.maxBytes
        self.urlSessionConfigurationOverride = urlSessionConfigurationOverride
        self.redirectPolicy = redirectPolicy
        self.allowsInsecureHTTP = allowsInsecureHTTP
    }
}
