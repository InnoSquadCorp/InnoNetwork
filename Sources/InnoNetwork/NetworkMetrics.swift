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

final class MetricsTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let reporter: any NetworkMetricsReporting

    init(request: URLRequest, reporter: any NetworkMetricsReporting) {
        self.request = request
        self.reporter = reporter
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        reporter.report(metrics: metrics, for: request, response: task.response)
    }
}

final class MetricsURLSession: URLSessionProtocol, @unchecked Sendable {
    private let session: URLSession
    private let reporter: any NetworkMetricsReporting

    /// - Note: URLSession/URLSessionTask do not guarantee Sendable, hence `@unchecked Sendable` is used.
    ///         Wraps an existing URLSession to preserve custom configuration behaviors.
    init(session: URLSession, reporter: any NetworkMetricsReporting) {
        self.session = session
        self.reporter = reporter
    }

    /// - Note: Convenience initializer for tests and standalone use.
    init(configuration: URLSessionConfiguration, reporter: any NetworkMetricsReporting) {
        self.session = URLSession(configuration: configuration)
        self.reporter = reporter
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let delegate = MetricsTaskDelegate(request: request, reporter: reporter)
        return try await session.data(for: request, delegate: delegate)
    }
}
