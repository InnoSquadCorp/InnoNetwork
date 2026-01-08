import Foundation


public protocol NetworkMetricsReporting: Sendable {
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
