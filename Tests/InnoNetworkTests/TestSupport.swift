import Foundation

@testable import InnoNetwork

func makeTestNetworkConfiguration(
    baseURL: String,
    timeout: TimeInterval = 30.0,
    cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
    requestPriority: RequestPriority = .normal,
    allowsCellularAccess: Bool = true,
    allowsExpensiveNetworkAccess: Bool = true,
    allowsConstrainedNetworkAccess: Bool = true,
    retryPolicy: RetryPolicy? = nil,
    networkMonitor: (any NetworkMonitoring)? = nil,
    metricsReporter: (any NetworkMetricsReporting)? = nil,
    trustPolicy: TrustPolicy = .systemDefault,
    eventObservers: [any NetworkEventObserving] = [],
    acceptableStatusCodes: Set<Int> = NetworkConfiguration.defaultAcceptableStatusCodes,
    requestInterceptors: [RequestInterceptor] = [],
    requestSigners: [RequestSigner] = [],
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
    responseBodyBufferingPolicy: ResponseBodyBufferingPolicy = .buffered(maxBytes: nil)
) -> NetworkConfiguration {
    NetworkConfiguration(
        baseURL: URL(string: baseURL)!,
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
        acceptableStatusCodes: acceptableStatusCodes,
        requestInterceptors: requestInterceptors,
        requestSigners: requestSigners,
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
        responseBodyBufferingPolicy: responseBodyBufferingPolicy
    )
}

extension NetworkError {
    /// The credential-boundary reason when this is a request credential failure.
    var credentialFailure: RequestSecurityFailure? {
        if case .authentication(.credential(let failure)) = self { return failure }
        return nil
    }

    /// The policy rejection payload when a local policy rejected the exchange.
    var policyRejection: NetworkPolicyRejection? {
        if case .policyRejected(let rejection) = self { return rejection }
        return nil
    }

    /// `(limit, observed)` when the response exceeded the body limit.
    var responseBodyLimit: (limitBytes: Int64, observedBytes: Int64)? {
        if case .policyRejected(.responseBodyLimitExceeded(let limitBytes, let observedBytes)) = self {
            return (limitBytes, observedBytes)
        }
        return nil
    }
}
