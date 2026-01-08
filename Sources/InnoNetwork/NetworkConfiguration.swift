import Foundation


public struct NetworkConfiguration: Sendable {
    public let baseURL: URL
    public let timeout: TimeInterval
    public let cachePolicy: URLRequest.CachePolicy
    public let retryPolicy: RetryPolicy?
    public let networkMonitor: (any NetworkMonitoring)?
    public let metricsReporter: (any NetworkMetricsReporting)?

    public init(
        baseURL: URL,
        timeout: TimeInterval = 30.0,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        retryPolicy: RetryPolicy? = nil,
        networkMonitor: (any NetworkMonitoring)? = nil,
        metricsReporter: (any NetworkMetricsReporting)? = nil
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.cachePolicy = cachePolicy
        self.retryPolicy = retryPolicy
        self.networkMonitor = networkMonitor
        self.metricsReporter = metricsReporter
    }
}
