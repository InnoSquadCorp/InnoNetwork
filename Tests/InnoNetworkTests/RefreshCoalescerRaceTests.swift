import Foundation
import Testing

@testable import InnoNetwork

// MARK: - Fixtures

private struct ProtectedUser: Codable, Sendable, Equatable {
    let id: Int
    let token: String
}


private struct ProtectedGet: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = ProtectedUser

    var method: HTTPMethod { .get }
    var path: String { "/me" }
}


private struct QueuedHTTPResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
}


/// Per-token routing session. The shared FIFO queue used elsewhere does
/// not work here because A and B's transports interleave — a strictly
/// ordered queue silently delivers one caller's retry payload to the
/// other. Routing on the request's `Authorization` header is the
/// deterministic choice.
private actor RoutingState {
    private let oldResponse: QueuedHTTPResponse
    private let newResponse: QueuedHTTPResponse
    private var requests: [URLRequest] = []

    init(oldResponse: QueuedHTTPResponse, newResponse: QueuedHTTPResponse) {
        self.oldResponse = oldResponse
        self.newResponse = newResponse
    }

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    func response(for request: URLRequest) -> QueuedHTTPResponse {
        let auth = request.value(forHTTPHeaderField: "Authorization")
        return auth == "Bearer NEW" ? newResponse : oldResponse
    }

    var requestCount: Int { requests.count }
    var capturedAuthorizations: [String?] {
        requests.map { $0.value(forHTTPHeaderField: "Authorization") }
    }
}


private final class RoutingSession: URLSessionProtocol, Sendable {
    private let state: RoutingState

    init(oldResponse: QueuedHTTPResponse, newResponse: QueuedHTTPResponse) {
        self.state = RoutingState(oldResponse: oldResponse, newResponse: newResponse)
    }

    var requestCount: Int { get async { await state.requestCount } }
    var capturedAuthorizations: [String?] {
        get async { await state.capturedAuthorizations }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await state.record(request)
        let queued = await state.response(for: request)
        return (queued.data, queued.response)
    }

    func upload(for request: URLRequest, from bodyData: Data) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}


private actor RefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}


private actor TokenStore {
    private var current: String

    init(initial: String) { self.current = initial }

    func read() -> String { current }
    func rotate(to next: String) { current = next }
}


private func queued(
    statusCode: Int,
    body: ProtectedUser? = nil,
    headers: [String: String] = [:]
) throws -> QueuedHTTPResponse {
    let data = try body.map { try JSONEncoder().encode($0) } ?? Data()
    return QueuedHTTPResponse(
        data: data,
        response: HTTPURLResponse(
            url: URL(string: "https://api.example.com/me")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    )
}


// MARK: - Tests

@Suite("Refresh-aware coalescer race (P2.1)")
struct RefreshCoalescerRaceTests {

    @Test("Concurrent OLD-token callers during refresh both retry with NEW token")
    func concurrentCallersDuringRefreshBothRetryWithNewToken() async throws {
        // Two callers (A, B) both observe a 401 with OLD token. A wins
        // single-flight refresh; B awaits A's refresh and retries with the
        // new token.  Validates the existing single-flight invariant: no
        // caller is left holding a stale 401 even when their transports are
        // interleaved.
        let oldResponse = try queued(statusCode: 401)
        let newResponse = try queued(
            statusCode: 200,
            body: ProtectedUser(id: 1, token: "NEW")
        )
        let session = RoutingSession(oldResponse: oldResponse, newResponse: newResponse)

        let store = TokenStore(initial: "OLD")
        let gate = RefreshGate()
        let policy = RefreshTokenPolicy(
            currentToken: { await store.read() },
            refreshToken: {
                await gate.wait()
                await store.rotate(to: "NEW")
                return "NEW"
            }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                requestInterceptors: [],
                refreshTokenPolicy: policy,
                requestCoalescingPolicy: .getOnly
            ),
            session: session
        )

        await withTaskGroup(of: ProtectedUser?.self) { group in
            group.addTask {
                try? await client.request(ProtectedGet())
            }
            group.addTask {
                // Stagger B slightly so A registers its refresh first.
                try? await Task.sleep(for: .milliseconds(20))
                return try? await client.request(ProtectedGet())
            }
            // Release the refresh after both callers have entered the
            // refresh path.
            try? await Task.sleep(for: .milliseconds(80))
            await gate.release()

            var users: [ProtectedUser] = []
            for await user in group {
                if let user { users.append(user) }
            }
            #expect(users.count == 2)
            #expect(users.allSatisfy { $0.token == "NEW" })
        }

        let captured = await session.capturedAuthorizations
        let oldCount = captured.filter { $0 == "Bearer OLD" }.count
        let newCount = captured.filter { $0 == "Bearer NEW" }.count
        // Each caller must hit the wire at least once with OLD before
        // observing 401, and the retry leg must carry the NEW token. The
        // post-refresh retries may coalesce (same dedup key, same token,
        // refresh no longer in progress), so newCount >= 1 is sufficient.
        #expect(oldCount >= 1, "at least one OLD transport must reach the wire (got \(captured))")
        #expect(newCount >= 1, "post-refresh retry must carry the new token (got \(captured))")
        #expect(captured.allSatisfy { $0 == "Bearer OLD" || $0 == "Bearer NEW" })
    }

    @Test("RefreshTokenCoordinator.isRefreshInProgress reports refresh state")
    func isRefreshInProgressReportsLifecycle() async throws {
        let gate = RefreshGate()
        let policy = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: {
                await gate.wait()
                return "new"
            }
        )
        let coordinator = RefreshTokenCoordinator(policy: policy)

        #expect(await coordinator.isRefreshInProgress == false)

        let request = URLRequest(url: URL(string: "https://api.example.com/me")!)
        async let refreshed = coordinator.refreshAndApply(to: request)

        // Give the detached refresh task a moment to register inFlight.
        try await Task.sleep(for: .milliseconds(20))
        #expect(await coordinator.isRefreshInProgress == true)

        await gate.release()
        _ = try await refreshed
        #expect(await coordinator.isRefreshInProgress == false)
    }

    @Test("RequestDedupKey distinguishes refreshLane suffix")
    func dedupKeyDistinguishesRefreshLane() throws {
        var request = URLRequest(url: URL(string: "https://api.example.com/me")!)
        request.httpMethod = "GET"
        request.setValue("Bearer OLD", forHTTPHeaderField: "Authorization")

        let policy = RequestCoalescingPolicy.getOnly
        let withoutLane = RequestDedupKey(request: request, policy: policy, refreshLane: nil)
        let laneA = RequestDedupKey(request: request, policy: policy, refreshLane: UUID())
        let laneB = RequestDedupKey(request: request, policy: policy, refreshLane: UUID())

        #expect(withoutLane != laneA)
        #expect(laneA != laneB, "different lanes must hash to different dedup keys")
        #expect(withoutLane == withoutLane)
    }
}
