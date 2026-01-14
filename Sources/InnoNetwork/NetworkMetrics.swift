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

final class MetricsSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let reporter: any NetworkMetricsReporting

    init(reporter: any NetworkMetricsReporting) {
        self.reporter = reporter
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard let request = task.originalRequest else { return }
        reporter.report(metrics: metrics, for: request, response: task.response)
    }
}

final class MetricsURLSession: NSObject, URLSessionProtocol, @unchecked Sendable {
    private let session: URLSession
    private let delegate: MetricsSessionDelegate

    /// - Note: URLSession/URLSessionTask do not guarantee Sendable, hence `@unchecked Sendable` is used.
    ///         Creates a new URLSession with the provided URLSessionConfiguration.
    ///         The original URLSession's delegateQueue and other settings are not preserved.
    init(configuration: URLSessionConfiguration, reporter: any NetworkMetricsReporting) {
        let delegate = MetricsSessionDelegate(reporter: reporter)
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.delegate = delegate
        super.init()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
