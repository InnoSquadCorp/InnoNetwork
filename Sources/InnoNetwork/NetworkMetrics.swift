import Foundation


/// 네트워크 요청의 URLSession 메트릭을 수집하기 위한 리포터입니다.
/// - Note: `report(metrics:for:response:)`는 URLSession delegate 콜백에서 호출될 수 있습니다.
/// - Important: 구현체는 스레드 안전성을 고려해야 합니다.
public protocol NetworkMetricsReporting: Sendable {
    /// URLSessionTaskMetrics가 수집된 시점에 호출됩니다.
    /// - Parameters:
    ///   - metrics: 수집된 URLSessionTaskMetrics 정보입니다.
    ///   - request: 원본 URLRequest입니다.
    ///   - response: 서버 응답입니다(실패 시 `nil`일 수 있음).
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

    /// - Note: 전달된 URLSessionConfiguration으로 새 URLSession을 생성합니다.
    ///         기존 URLSession의 delegateQueue 등은 유지되지 않습니다.
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
