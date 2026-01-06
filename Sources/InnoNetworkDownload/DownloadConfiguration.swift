import Foundation


public struct DownloadConfiguration: Sendable {
    public let maxConcurrentDownloads: Int
    public let maxRetryCount: Int
    public let retryDelay: TimeInterval
    public let timeoutForRequest: TimeInterval
    public let timeoutForResource: TimeInterval
    public let allowsCellularAccess: Bool
    public let sessionIdentifier: String
    
    public init(
        maxConcurrentDownloads: Int = 3,
        maxRetryCount: Int = 3,
        retryDelay: TimeInterval = 1.0,
        timeoutForRequest: TimeInterval = 30,
        timeoutForResource: TimeInterval = 60 * 60 * 24,
        allowsCellularAccess: Bool = true,
        sessionIdentifier: String = "com.innonetwork.download"
    ) {
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.maxRetryCount = maxRetryCount
        self.retryDelay = retryDelay
        self.timeoutForRequest = timeoutForRequest
        self.timeoutForResource = timeoutForResource
        self.allowsCellularAccess = allowsCellularAccess
        self.sessionIdentifier = sessionIdentifier
    }
    
    public static let `default` = DownloadConfiguration()
    
    func makeURLSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = allowsCellularAccess
        config.timeoutIntervalForRequest = timeoutForRequest
        config.timeoutIntervalForResource = timeoutForResource
        config.httpMaximumConnectionsPerHost = maxConcurrentDownloads
        return config
    }
}
