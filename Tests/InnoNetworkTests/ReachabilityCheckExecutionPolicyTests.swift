import Foundation
import Testing

@testable import InnoNetwork

@Suite
struct ReachabilityCheckExecutionPolicyTests {
    @Test
    func rejectsRequestWhenSnapshotUnsatisfied() async throws {
        let monitor = StubMonitor(
            snapshot: NetworkSnapshot(status: .unsatisfied, interfaceTypes: [.cellular])
        )
        let policy = ReachabilityCheckExecutionPolicy(monitor: monitor)

        let url = URL(string: "https://api.example.com/x")!
        do {
            _ = try await policy.execute(
                input: RequestExecutionInput(request: URLRequest(url: url), requestID: UUID(), retryIndex: 0),
                context: makeContext(),
                next: RequestExecutionNext { request in
                    Issue.record("Chain should not run when offline")
                    return Response(
                        statusCode: 200,
                        data: Data(),
                        request: request,
                        response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    )
                }
            )
            Issue.record("Expected throw, got success")
        } catch let error as NetworkError {
            guard case .invalidRequestConfiguration = error else {
                Issue.record("Expected .invalidRequestConfiguration, got \(error)")
                return
            }
        }
    }

    @Test
    func forwardsWhenSnapshotSatisfied() async throws {
        let monitor = StubMonitor(
            snapshot: NetworkSnapshot(status: .satisfied, interfaceTypes: [.wifi])
        )
        let policy = ReachabilityCheckExecutionPolicy(monitor: monitor)

        let url = URL(string: "https://api.example.com/x")!
        let response = try await policy.execute(
            input: RequestExecutionInput(request: URLRequest(url: url), requestID: UUID(), retryIndex: 0),
            context: makeContext(),
            next: RequestExecutionNext { request in
                Response(
                    statusCode: 200,
                    data: Data(),
                    request: request,
                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )

        #expect(response.statusCode == 200)
    }

    @Test
    func warnOnlyModeForwardsEvenWhenOffline() async throws {
        let monitor = StubMonitor(
            snapshot: NetworkSnapshot(status: .unsatisfied, interfaceTypes: [])
        )
        let policy = ReachabilityCheckExecutionPolicy(monitor: monitor, mode: .warnOnly)

        let url = URL(string: "https://api.example.com/x")!
        let response = try await policy.execute(
            input: RequestExecutionInput(request: URLRequest(url: url), requestID: UUID(), retryIndex: 0),
            context: makeContext(),
            next: RequestExecutionNext { request in
                Response(
                    statusCode: 200,
                    data: Data(),
                    request: request,
                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )

        #expect(response.statusCode == 200)
    }

    @Test
    func nilSnapshotFallsThrough() async throws {
        let monitor = StubMonitor(snapshot: nil)
        let policy = ReachabilityCheckExecutionPolicy(monitor: monitor)

        let url = URL(string: "https://api.example.com/x")!
        let response = try await policy.execute(
            input: RequestExecutionInput(request: URLRequest(url: url), requestID: UUID(), retryIndex: 0),
            context: makeContext(),
            next: RequestExecutionNext { request in
                Response(
                    statusCode: 200,
                    data: Data(),
                    request: request,
                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )

        #expect(response.statusCode == 200)
    }
}

private func makeContext() -> RequestExecutionContext {
    RequestExecutionContext(
        requestID: UUID(),
        retryIndex: 0,
        metricsReporter: nil,
        trustPolicy: .systemDefault,
        eventObservers: []
    )
}

private struct StubMonitor: NetworkMonitoring {
    let snapshot: NetworkSnapshot?

    func currentSnapshot() async -> NetworkSnapshot? {
        snapshot
    }

    func waitForChange(from snapshot: NetworkSnapshot?, timeout: TimeInterval?) async -> NetworkSnapshot? {
        nil
    }
}
