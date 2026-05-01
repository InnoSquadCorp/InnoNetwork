import Foundation

@testable import InnoNetwork

func makeTestNetworkConfiguration(
    baseURL: String,
    timeout: TimeInterval = 30.0,
    cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
    retryPolicy: RetryPolicy? = nil,
    networkMonitor: (any NetworkMonitoring)? = nil,
    metricsReporter: (any NetworkMetricsReporting)? = nil,
    trustPolicy: TrustPolicy = .systemDefault,
    eventObservers: [any NetworkEventObserving] = [],
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
) -> NetworkConfiguration {
    NetworkConfiguration(
        baseURL: URL(string: baseURL)!,
        timeout: timeout,
        cachePolicy: cachePolicy,
        retryPolicy: retryPolicy,
        networkMonitor: networkMonitor,
        metricsReporter: metricsReporter,
        trustPolicy: trustPolicy,
        eventObservers: eventObservers,
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
