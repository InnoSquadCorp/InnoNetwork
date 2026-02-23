import Foundation


public struct NetworkConfiguration: Sendable {
    public let baseURL: URL
    public let timeout: TimeInterval
    public let cachePolicy: URLRequest.CachePolicy
    public let retryPolicy: RetryPolicy?
    public let networkMonitor: (any NetworkMonitoring)?
    public let metricsReporter: (any NetworkMetricsReporting)?
    public let trustPolicy: TrustPolicy
    public let eventObservers: [any NetworkEventObserving]

    public init(
        baseURL: URL,
        timeout: TimeInterval = 30.0,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        retryPolicy: RetryPolicy? = nil,
        networkMonitor: (any NetworkMonitoring)? = NetworkMonitor.shared,
        metricsReporter: (any NetworkMetricsReporting)? = nil,
        trustPolicy: TrustPolicy = .systemDefault,
        eventObservers: [any NetworkEventObserving] = []
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.cachePolicy = cachePolicy
        self.retryPolicy = retryPolicy
        self.networkMonitor = networkMonitor
        self.metricsReporter = metricsReporter
        self.trustPolicy = trustPolicy
        self.eventObservers = eventObservers
    }
}
