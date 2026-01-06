import Foundation


public struct NetworkConfiguration: Sendable {
    public let baseURL: URL
    public let timeout: TimeInterval
    public let cachePolicy: URLRequest.CachePolicy
    public let retryPolicy: RetryPolicy?

    public init(
        baseURL: URL,
        timeout: TimeInterval = 30.0,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        retryPolicy: RetryPolicy? = nil
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.cachePolicy = cachePolicy
        self.retryPolicy = retryPolicy
    }
}
