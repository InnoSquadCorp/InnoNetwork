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
                retryPolicy: nil,
                networkMonitor: NetworkMonitor.shared,
                metricsReporter: nil,
                trustPolicy: .systemDefault,
                eventObservers: [],
                eventDeliveryPolicy: .default,
                eventMetricsReporter: nil,
                acceptableStatusCodes: NetworkConfiguration.defaultAcceptableStatusCodes,
                requestInterceptors: [],
                responseInterceptors: []
            )
        }

        static func advancedTuning(baseURL: URL) -> NetworkConfiguration {
            NetworkConfiguration(
                baseURL: baseURL,
                timeout: 60.0,
                cachePolicy: .reloadIgnoringLocalCacheData,
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
                responseInterceptors: []
            )
        }
    }

    public let baseURL: URL
    public let timeout: TimeInterval
    public let cachePolicy: URLRequest.CachePolicy
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

    /// When `false` (default), response bodies attached to ``NetworkError``
    /// cases (`objectMapping`, `jsonMapping`, `statusCode`, and `underlying`
    /// when present) are zeroed out before the error is logged or surfaced
    /// to consumers, so PII in failure payloads cannot accidentally leak
    /// into crash logs, analytics, or error reporting. Status code, headers,
    /// and the original `URLRequest` are preserved.
    ///
    /// Set this to `true` only in diagnostic configurations where capturing
    /// the failing response body is worth the privacy trade-off.
    public let captureFailurePayload: Bool

    /// Optional ceiling on the size of buffered response bodies, in bytes.
    /// When `nil` (default) the executor enforces no limit and behaves
    /// exactly as in 4.0. When set, the executor compares the received
    /// `Data` length against the limit after transport completes and
    /// throws ``NetworkError/responseTooLarge(limit:observed:)`` if the
    /// payload exceeds it, before the body is handed to the decoder.
    ///
    /// > Note: This is a soft guard, not a streaming bound. Foundation's
    /// > `URLSession.data(for:)` has already buffered the body in memory
    /// > by the time the check runs. The benefit is a structured error
    /// > (and a stable failure mode for retry/circuit-breaker policies)
    /// > rather than an opaque OOM in the consumer or the decoder.
    /// > Endpoints that need genuine memory-bounded handling should use
    /// > the streaming surface (`stream(_:)` or `bytes(for:)`).
    public let responseBodyLimit: Int64?

    public struct AdvancedBuilder: Sendable {
        public var baseURL: URL
        public var timeout: TimeInterval
        public var cachePolicy: URLRequest.CachePolicy
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
        public var captureFailurePayload: Bool
        public var responseBodyLimit: Int64?

        fileprivate init(preset: NetworkConfiguration) {
            self.baseURL = preset.baseURL
            self.timeout = preset.timeout
            self.cachePolicy = preset.cachePolicy
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
            self.captureFailurePayload = preset.captureFailurePayload
            self.responseBodyLimit = preset.responseBodyLimit
        }

        fileprivate func build() -> NetworkConfiguration {
            NetworkConfiguration(
                baseURL: baseURL,
                timeout: timeout,
                cachePolicy: cachePolicy,
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
                captureFailurePayload: captureFailurePayload,
                responseBodyLimit: responseBodyLimit
            )
        }
    }

    public static func safeDefaults(baseURL: URL) -> NetworkConfiguration {
        Presets.safeDefaults(baseURL: baseURL)
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
        captureFailurePayload: Bool = false,
        responseBodyLimit: Int64? = nil
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.cachePolicy = cachePolicy
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
        self.captureFailurePayload = captureFailurePayload
        self.responseBodyLimit = responseBodyLimit
    }
}
