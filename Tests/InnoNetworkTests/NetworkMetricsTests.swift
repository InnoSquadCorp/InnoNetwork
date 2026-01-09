import Foundation
import Testing
@testable import InnoNetwork


final class MetricsRecorder: NetworkMetricsReporting, @unchecked Sendable {
    private var metrics: [URLSessionTaskMetrics] = []
    private var responses: [URLResponse?] = []
    private let lock = NSLock()

    func report(metrics: URLSessionTaskMetrics, for request: URLRequest, response: URLResponse?) {
        lock.lock()
        self.metrics.append(metrics)
        responses.append(response)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        let value = metrics.count
        lock.unlock()
        return value
    }

    var lastResponse: URLResponse? {
        lock.lock()
        let value = responses.last ?? nil
        lock.unlock()
        return value
    }
}


final class TestURLProtocol: URLProtocol {
    enum ResponseSpec {
        case success(statusCode: Int, data: Data)
        case failure(Error)
    }

    private static var responses: [ResponseSpec] = []
    private static let lock = NSLock()

    static func enqueue(_ response: ResponseSpec) {
        lock.lock()
        responses.append(response)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        responses.removeAll()
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let responseSpec = Self.dequeue()
        switch responseSpec {
        case .success(let statusCode, let data):
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            if let httpResponse = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil) {
                client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .none:
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        }
    }

    override func stopLoading() {}

    private static func dequeue() -> ResponseSpec? {
        lock.lock()
        let value = responses.isEmpty ? nil : responses.removeFirst()
        lock.unlock()
        return value
    }
}


struct MetricsTestAPI: APIConfigure {
    var host: String { "https://example.com" }
    var basePath: String { "api" }
}


struct MetricsGetRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = String

    var method: HTTPMethod { .get }
    var path: String { "/metrics" }
}


struct RetryOncePolicy: RetryPolicy {
    let maxRetries: Int = 1
    let retryDelay: TimeInterval = 0

    func shouldRetry(error: NetworkError, attempt: Int) -> Bool {
        guard attempt < maxRetries else { return false }
        switch error {
        case .underlying:
            return true
        case .nonHTTPResponse:
            return true
        default:
            return false
        }
    }
}


@Suite("Network Metrics Tests")
struct NetworkMetricsTests {

    @Test("Metrics are reported for successful requests")
    func reportsMetricsForSuccessfulRequest() async throws {
        TestURLProtocol.reset()
        TestURLProtocol.enqueue(.success(statusCode: 200, data: Data("ok".utf8)))

        let recorder = MetricsRecorder()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        let session = MetricsURLSession(configuration: config, reporter: recorder)

        let request = URLRequest(url: URL(string: "https://example.com/api/metrics")!)
        _ = try await session.data(for: request)

        let reported = await waitForMetrics(recorder: recorder, count: 1)
        #expect(reported)
        if let response = recorder.lastResponse as? HTTPURLResponse {
            #expect(response.statusCode == 200)
        } else {
            #expect(false)
        }
    }

    @Test("Metrics are reported for failed requests")
    func reportsMetricsForFailedRequest() async throws {
        TestURLProtocol.reset()
        TestURLProtocol.enqueue(.failure(URLError(.timedOut)))

        let recorder = MetricsRecorder()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        let session = MetricsURLSession(configuration: config, reporter: recorder)

        let request = URLRequest(url: URL(string: "https://example.com/api/metrics")!)
        await #expect(throws: URLError.self) {
            _ = try await session.data(for: request)
        }

        let reported = await waitForMetrics(recorder: recorder, count: 1)
        #expect(reported)
    }

    @Test("Metrics are reported for retried requests")
    func reportsMetricsForRetriedRequest() async throws {
        TestURLProtocol.reset()
        TestURLProtocol.enqueue(.failure(URLError(.cannotConnectToHost)))
        TestURLProtocol.enqueue(.success(statusCode: 200, data: Data(#""value""#.utf8)))

        let recorder = MetricsRecorder()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        let urlSession = URLSession(configuration: config)

        let networkConfiguration = NetworkConfiguration(
            baseURL: URL(string: "https://example.com/api")!,
            retryPolicy: RetryOncePolicy(),
            networkMonitor: nil,
            metricsReporter: recorder
        )
        let client = try DefaultNetworkClient(
            configuration: MetricsTestAPI(),
            networkConfiguration: networkConfiguration,
            session: urlSession
        )

        let result = try await client.request(MetricsGetRequest())
        #expect(result == "value")

        let reported = await waitForMetrics(recorder: recorder, count: 2)
        #expect(reported)
    }

    private func waitForMetrics(recorder: MetricsRecorder, count: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if recorder.count >= count {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}
