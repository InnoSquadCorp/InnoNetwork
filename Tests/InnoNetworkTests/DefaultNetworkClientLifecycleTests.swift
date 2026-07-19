import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork

private struct LifecycleResponse: Codable, Equatable, Sendable {
    let ok: Bool
}

private struct LifecycleEndpoint: APIDefinition {
    var sessionAuthentication: SessionAuthentication { .anonymous }
    typealias Parameter = EmptyParameter
    typealias APIResponse = LifecycleResponse

    var method: HTTPMethod { .get }
    var path: String { "/lifecycle" }
}

private actor SleepingURLSession: URLSessionProtocol {
    private var recordedRequestCount = 0

    var requestCount: Int {
        recordedRequestCount
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        _ = request
        recordedRequestCount += 1
        try await Task.sleep(for: .seconds(30))
        throw URLError(.cancelled)
    }
}

private final class LifecycleMetricRecorder: EventPipelineMetricsReporting, Sendable {
    private let metricCount = OSAllocatedUnfairLock<Int>(initialState: 0)

    func report(_ metric: EventPipelineMetric) {
        _ = metric
        metricCount.withLock { $0 += 1 }
    }

    var count: Int {
        metricCount.withLock { $0 }
    }
}

@Suite("DefaultNetworkClient Lifecycle Tests")
struct DefaultNetworkClientLifecycleTests {

    @Test("request after shutdown fails without hitting transport")
    func requestAfterShutdownFailsWithoutTransport() async throws {
        let session = MockURLSession()
        try session.setMockJSON(LifecycleResponse(ok: true))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com"),
            session: session
        )

        await client.shutdown()

        do {
            _ = try await client.request(LifecycleEndpoint())
            Issue.record("Expected request after shutdown to fail")
        } catch let error {
            guard case .cancelled = error else {
                Issue.record("Expected NetworkError.cancelled, got \(error)")
                return
            }
        }
        #expect(session.capturedRequestsInOrder.isEmpty)
    }

    @Test("shutdown cancels in-flight request")
    func shutdownCancelsInFlightRequest() async throws {
        let session = SleepingURLSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com"),
            session: session
        )

        let requestTask = Task {
            try await client.request(LifecycleEndpoint())
        }

        #expect(await waitForLifecycleCondition { await session.requestCount == 1 })
        await client.shutdown()

        do {
            _ = try await requestTask.value
            Issue.record("Expected in-flight request to be cancelled")
        } catch let error as NetworkError {
            guard case .cancelled = error else {
                Issue.record("Expected NetworkError.cancelled, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("shutdown stops event metrics work while client remains retained")
    func shutdownStopsEventMetricsWork() async {
        let reporter = LifecycleMetricRecorder()
        let clock = TestClock()
        let configuration = NetworkConfiguration.advanced(
            baseURL: URL(string: "https://api.example.com")!,
            observability: ObservabilityPack(eventMetricsReporter: reporter)
        )
        let client = DefaultNetworkClient(
            configuration: configuration,
            session: MockURLSession(),
            clock: clock
        )

        #expect(await clock.waitForWaiters(count: 1))
        await client.shutdown()

        #expect(clock.waiterCount == 0)
        let metricCount = reporter.count
        clock.advance(by: .seconds(60))
        await Task.yield()
        #expect(reporter.count == metricCount)
        _ = client
    }
}

private func waitForLifecycleCondition(
    timeout: TimeInterval = 1.0,
    predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await predicate()
}
