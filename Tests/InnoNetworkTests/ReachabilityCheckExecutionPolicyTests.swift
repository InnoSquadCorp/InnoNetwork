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
            guard case .configuration(let reason) = error,
                case .offline = reason
            else {
                Issue.record("Expected .configuration(.offline), got \(error)")
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
    func requireOnlineThrowsTransportSuspendedWhenRequiresConnectionPersists() async throws {
        let monitor = StubMonitor(
            snapshot: NetworkSnapshot(status: .requiresConnection, interfaceTypes: [.wifi])
        )
        let policy = ReachabilityCheckExecutionPolicy(
            monitor: monitor,
            suspensionWaitTimeout: 0
        )

        let url = URL(string: "https://api.example.com/x")!
        do {
            _ = try await policy.execute(
                input: RequestExecutionInput(request: URLRequest(url: url), requestID: UUID(), retryIndex: 0),
                context: makeContext(),
                next: RequestExecutionNext { request in
                    Issue.record("Chain should not run while reachability is suspended")
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
            guard case .underlying(let underlying, _) = error,
                underlying.code == 4002
            else {
                Issue.record("Expected .underlying with code 4002 (transport suspended), got \(error)")
                return
            }
        }
        #expect(await monitor.waitForChangeCallCount() == 1)
    }

    @Test
    func requireOnlineForwardsWhenRequiresConnectionBecomesSatisfied() async throws {
        let monitor = StubMonitor(
            snapshot: NetworkSnapshot(status: .requiresConnection, interfaceTypes: [.wifi]),
            nextChangeSnapshot: NetworkSnapshot(status: .satisfied, interfaceTypes: [.wifi])
        )
        let policy = ReachabilityCheckExecutionPolicy(
            monitor: monitor,
            suspensionWaitTimeout: 0
        )

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
        #expect(await monitor.waitForChangeCallCount() == 1)
    }

    @Test
    func requireOnlineThrowsOfflineWhenRequiresConnectionBecomesUnsatisfied() async throws {
        let monitor = StubMonitor(
            snapshot: NetworkSnapshot(status: .requiresConnection, interfaceTypes: [.wifi]),
            nextChangeSnapshot: NetworkSnapshot(status: .unsatisfied, interfaceTypes: [])
        )
        let policy = ReachabilityCheckExecutionPolicy(
            monitor: monitor,
            suspensionWaitTimeout: 0
        )

        let url = URL(string: "https://api.example.com/x")!
        do {
            _ = try await policy.execute(
                input: RequestExecutionInput(request: URLRequest(url: url), requestID: UUID(), retryIndex: 0),
                context: makeContext(),
                next: RequestExecutionNext { request in
                    Issue.record("Chain should not run after reachability becomes offline")
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
            guard case .configuration(let reason) = error,
                case .offline = reason
            else {
                Issue.record("Expected .configuration(.offline), got \(error)")
                return
            }
        }
        #expect(await monitor.waitForChangeCallCount() == 1)
    }

    @Test
    func warnOnlyModeForwardsRequiresConnectionWithoutWaiting() async throws {
        let monitor = StubMonitor(
            snapshot: NetworkSnapshot(status: .requiresConnection, interfaceTypes: [.wifi])
        )
        let policy = ReachabilityCheckExecutionPolicy(
            monitor: monitor,
            mode: .warnOnly,
            suspensionWaitTimeout: 0
        )

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
        #expect(await monitor.waitForChangeCallCount() == 0)
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

private actor StubMonitor: NetworkMonitoring {
    let snapshot: NetworkSnapshot?
    let nextChangeSnapshot: NetworkSnapshot?
    private var waitCount = 0

    init(snapshot: NetworkSnapshot?, nextChangeSnapshot: NetworkSnapshot? = nil) {
        self.snapshot = snapshot
        self.nextChangeSnapshot = nextChangeSnapshot
    }

    func currentSnapshot() async -> NetworkSnapshot? {
        snapshot
    }

    func waitForChange(from snapshot: NetworkSnapshot?, timeout: TimeInterval?) async -> NetworkSnapshot? {
        _ = snapshot
        _ = timeout
        waitCount += 1
        return nextChangeSnapshot
    }

    func waitForChangeCallCount() -> Int {
        waitCount
    }
}
