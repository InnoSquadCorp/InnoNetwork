import Foundation
import InnoNetwork


public struct DownloadConfiguration: Sendable {
    public let maxConcurrentDownloads: Int
    public let maxRetryCount: Int
    public let retryDelay: TimeInterval
    public let timeoutForRequest: TimeInterval
    public let timeoutForResource: TimeInterval
    public let allowsCellularAccess: Bool
    public let sessionIdentifier: String
    public let networkMonitor: (any NetworkMonitoring)?
    /// 기본값이 true이므로, 다운로드 실패 시 네트워크 변화가 감지될 때까지 대기할 수 있습니다.
    public let waitsForNetworkChanges: Bool
    public let networkChangeTimeout: TimeInterval?
    
    public init(
        maxConcurrentDownloads: Int = 3,
        maxRetryCount: Int = 3,
        retryDelay: TimeInterval = 1.0,
        timeoutForRequest: TimeInterval = 30,
        timeoutForResource: TimeInterval = 60 * 60 * 24,
        allowsCellularAccess: Bool = true,
        sessionIdentifier: String = "com.innonetwork.download",
        networkMonitor: (any NetworkMonitoring)? = NetworkMonitor.shared,
        waitsForNetworkChanges: Bool = true,
        networkChangeTimeout: TimeInterval? = 10.0
    ) {
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.maxRetryCount = maxRetryCount
        self.retryDelay = retryDelay
        self.timeoutForRequest = timeoutForRequest
        self.timeoutForResource = timeoutForResource
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
