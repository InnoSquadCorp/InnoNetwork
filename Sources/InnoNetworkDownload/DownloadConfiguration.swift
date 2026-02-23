import Foundation
import InnoNetwork


public struct DownloadConfiguration: Sendable {
    public let maxConcurrentDownloads: Int
    public let maxRetryCount: Int
    /// Maximum total retry count even if the counter is reset due to network changes.
    public let maxTotalRetries: Int
    public let retryDelay: TimeInterval
    public let timeoutForRequest: TimeInterval
    public let timeoutForResource: TimeInterval
    public let allowsCellularAccess: Bool
    public let sessionIdentifier: String
    public let networkMonitor: (any NetworkMonitoring)?
    /// When true, waits for network changes before retrying on download failure.
    public let waitsForNetworkChanges: Bool
    public let networkChangeTimeout: TimeInterval?
    
    public init(
        maxConcurrentDownloads: Int = 3,
        maxRetryCount: Int = 3,
        maxTotalRetries: Int = 3,
        retryDelay: TimeInterval = 1.0,
        timeoutForRequest: TimeInterval = 30,
        timeoutForResource: TimeInterval = 60 * 60 * 24,
        allowsCellularAccess: Bool = true,
        sessionIdentifier: String = "com.innonetwork.download",
        networkMonitor: (any NetworkMonitoring)? = NetworkMonitor.shared,
        waitsForNetworkChanges: Bool = false,
        networkChangeTimeout: TimeInterval? = 10.0
    ) {
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
        self.maxRetryCount = max(0, maxRetryCount)
        self.maxTotalRetries = max(0, maxTotalRetries)
        self.retryDelay = max(0, retryDelay)
        self.timeoutForRequest = max(0, timeoutForRequest)
        self.timeoutForResource = max(0, timeoutForResource)
        self.allowsCellularAccess = allowsCellularAccess
        self.sessionIdentifier = sessionIdentifier
        self.networkMonitor = networkMonitor
        self.waitsForNetworkChanges = waitsForNetworkChanges
        self.networkChangeTimeout = networkChangeTimeout
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
