import Foundation
import Testing
@testable import InnoNetwork


actor MetricsRecorder: NetworkMetricsReporting {
    private var metrics: [URLSessionTaskMetrics] = []
    private var responses: [URLResponse?] = []

    nonisolated func report(metrics: URLSessionTaskMetrics, for request: URLRequest, response: URLResponse?) {
        Task { await record(metrics: metrics, response: response) }
    }

    private func record(metrics: URLSessionTaskMetrics, response: URLResponse?) {
        self.metrics.append(metrics)
        self.responses.append(response)
    }

    var count: Int {
        metrics.count
    }

    var lastResponse: URLResponse? {
        responses.last ?? nil
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
    let maxTotalRetries: Int = 1
    let retryDelay: TimeInterval = 0

    func retryDelay(for attempt: Int) -> TimeInterval {
        retryDelay
    }

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
        if let response = await recorder.lastResponse as? HTTPURLResponse {
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
            if await recorder.count >= count {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}

@Suite("Network Monitor Tests")
struct NetworkMonitorTests {

    @Test("NetworkSnapshot init sets status and interface types")
    func snapshotInit() {
        let snapshot = NetworkSnapshot(status: .satisfied, interfaceTypes: [.wifi, .cellular])
        #expect(snapshot.status == .satisfied)
        #expect(snapshot.interfaceTypes == [.wifi, .cellular])
    }

    @Test("waitForChange returns nil or a different snapshot on timeout")
    func waitForChangeTimeout() async {
        let monitor = NetworkMonitor()
        let snapshot = await monitor.currentSnapshot()
        let result = await monitor.waitForChange(from: snapshot, timeout: 0.05)
        if let result {
            #expect(result != snapshot)
        } else {
            #expect(result == nil)
        }
    }
}

@Suite("Retry Policy Tests")
struct RetryPolicyTests {

    @Test("ExponentialBackoffRetryPolicy uses base delay on first attempt")
    func backoffBaseDelay() {
        let policy = ExponentialBackoffRetryPolicy(
            maxRetries: 3,
            maxTotalRetries: 3,
            retryDelay: 1.5,
            maxDelay: 10,
            jitterRatio: 0.0,
            waitsForNetworkChanges: false,
            networkChangeTimeout: nil
        )
        let delay = policy.retryDelay(for: 0)
        #expect(delay == 1.5)
    }

    @Test("ExponentialBackoffRetryPolicy grows delay with attempts")
    func backoffGrowth() {
        let policy = ExponentialBackoffRetryPolicy(
            maxRetries: 3,
            maxTotalRetries: 3,
            retryDelay: 1.0,
            maxDelay: 10,
            jitterRatio: 0.0,
            waitsForNetworkChanges: false,
            networkChangeTimeout: nil
        )
        #expect(policy.retryDelay(for: 0) == 1.0)
        #expect(policy.retryDelay(for: 1) == 2.0)
        #expect(policy.retryDelay(for: 2) == 4.0)
    }

    @Test("ExponentialBackoffRetryPolicy evaluates retryable status codes")
    func statusCodeRetryable() {
        let response = Response(
            statusCode: 503,
            data: Data(),
            request: nil,
            response: HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
        )
        let policy = ExponentialBackoffRetryPolicy(
            maxRetries: 1,
            maxTotalRetries: 1,
            retryDelay: 1,
            maxDelay: 10,
            jitterRatio: 0,
            waitsForNetworkChanges: false,
            networkChangeTimeout: nil
        )
        #expect(policy.shouldRetry(error: .statusCode(response), attempt: 0))
    }

    @Test("shouldResetAttempts detects snapshot changes")
    func resetAttemptsOnSnapshotChange() {
        let policy = ExponentialBackoffRetryPolicy(
            maxRetries: 1,
            maxTotalRetries: 1,
            retryDelay: 1,
            maxDelay: 10,
            jitterRatio: 0,
            waitsForNetworkChanges: true,
            networkChangeTimeout: 0.1
        )
        let oldSnapshot = NetworkSnapshot(status: .satisfied, interfaceTypes: [.wifi])
        let newSnapshot = NetworkSnapshot(status: .satisfied, interfaceTypes: [.cellular])
        #expect(policy.shouldResetAttempts(afterNetworkChangeFrom: oldSnapshot, to: newSnapshot))
    }
}
