import Foundation

/// Reporter for collecting URLSession metrics from network requests.
/// - Note: `report(metrics:for:response:)` may be called from URLSession delegate callbacks.
/// - Important: Implementations should be thread-safe.
public protocol NetworkMetricsReporting: Sendable {
    /// Called when URLSessionTaskMetrics is collected.
    /// - Parameters:
    ///   - metrics: The collected URLSessionTaskMetrics.
    ///   - request: The original URLRequest.
    ///   - response: The server response (may be `nil` on failure).
    func report(metrics: URLSessionTaskMetrics, for request: URLRequest, response: URLResponse?)
}
