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
    captureFailurePayload: Bool = false
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
        captureFailurePayload: captureFailurePayload
    )
}
