import Foundation


public protocol RetryPolicy: Sendable {
    var maxRetries: Int { get }
    var retryDelay: TimeInterval { get }
    func shouldRetry(error: NetworkError, attempt: Int) -> Bool
}
