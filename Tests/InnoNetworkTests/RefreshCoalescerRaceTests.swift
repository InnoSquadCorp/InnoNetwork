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
    var sessionAuthentication: SessionAuthentication { .optional }
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
    private var oldRequestCount = 0
    private var didObserveSecondOldRequest = false
    private var secondOldRequestObservers: [CheckedContinuation<Void, Never>] = []
    private var canFinishSecondOldRequest = false
    private var secondOldRequestWaiters: [CheckedContinuation<Void, Never>] = []

    init(oldResponse: QueuedHTTPResponse, newResponse: QueuedHTTPResponse) {
        self.oldResponse = oldResponse
        self.newResponse = newResponse
    }

    func response(for request: URLRequest) async -> QueuedHTTPResponse {
        requests.append(request)
        let auth = request.value(forHTTPHeaderField: "Authorization")
        guard auth != "Bearer NEW" else { return newResponse }

        oldRequestCount += 1
        if oldRequestCount == 2 {
            didObserveSecondOldRequest = true
            let observers = secondOldRequestObservers
            secondOldRequestObservers.removeAll()
            for observer in observers {
                observer.resume()
            }

            if !canFinishSecondOldRequest {
                await withCheckedContinuation { continuation in
                    secondOldRequestWaiters.append(continuation)
                }
            }
        }
        return oldResponse
    }

    func waitForSecondOldRequest() async {
        guard !didObserveSecondOldRequest else { return }
        await withCheckedContinuation { continuation in
            secondOldRequestObservers.append(continuation)
        }
    }

    func releaseSecondOldRequest() {
        canFinishSecondOldRequest = true
        let waiters = secondOldRequestWaiters
        secondOldRequestWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
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

    func waitForSecondOldRequest() async {
        await state.waitForSecondOldRequest()
    }

    func releaseSecondOldRequest() async {
        await state.releaseSecondOldRequest()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
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
    private var waitCount = 0
    private var waitCountObservers: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        waitCount += 1
        let observers = waitCountObservers
        waitCountObservers.removeAll()
        for observer in observers {
            observer.resume()
        }
        if released { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard waitCount == 0 else { return }
        await withCheckedContinuation { continuation in
            waitCountObservers.append(continuation)
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    var totalWaitCount: Int { waitCount }
}


private actor CancellableRefreshProbe {
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    func refreshToken() async throws -> String {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        do {
            try await Task.sleep(for: .seconds(60))
            return "new"
        } catch is CancellationError {
            cancelled = true
            cancelWaiters.forEach { $0.resume() }
            cancelWaiters.removeAll()
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilCancelled() async {
        if cancelled { return }
        await withCheckedContinuation { continuation in
            cancelWaiters.append(continuation)
        }
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

    @Test("Late OLD-token 401 reuses the completed refresh generation")
    func lateAuthenticationFailureReusesCompletedRefreshGeneration() async throws {
        // A starts a refresh after its OLD request receives 401. B reaches
        // transport while that refresh is in flight, but its OLD 401 is held
        // until A has completed both the refresh and its NEW-token replay.
        // B must observe the advanced generation and reapply the stored token
        // without launching a redundant second refresh.
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

        let first = Task { try await client.request(ProtectedGet()) }
        await gate.waitUntilEntered()

        let second = Task { try await client.request(ProtectedGet()) }
        await session.waitForSecondOldRequest()

        await gate.release()
        let firstUser = try await first.value
        #expect(firstUser.token == "NEW")

        await session.releaseSecondOldRequest()
        let secondUser = try await second.value
        #expect(secondUser.token == "NEW")

        let captured = await session.capturedAuthorizations
        #expect(captured == ["Bearer OLD", "Bearer OLD", "Bearer NEW", "Bearer NEW"])
        #expect(await gate.totalWaitCount == 1, "late 401 must not start a second refresh")
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

        await gate.waitUntilEntered()
        #expect(await coordinator.isRefreshInProgress == true)

        await gate.release()
        _ = try await refreshed
        #expect(await coordinator.isRefreshInProgress == false)
    }

    @Test("Cancelled refresh awaiter returns before shared refresh completes")
    func cancelledRefreshAwaiterReturnsBeforeSharedRefreshCompletes() async throws {
        let gate = RefreshGate()
        let policy = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: {
                await gate.wait()
                return "new"
            }
        )
        let coordinator = RefreshTokenCoordinator(policy: policy)
        let request = URLRequest(url: URL(string: "https://api.example.com/me")!)

        let waiter = Task {
            try await coordinator.refreshAndApply(to: request)
        }

        await gate.waitUntilEntered()
        #expect(await coordinator.isRefreshInProgress == true)

        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await waiter.value
        }

        #expect(await coordinator.isRefreshInProgress == true)
        let survivingWaiter = Task {
            try await coordinator.refreshAndApply(to: request)
        }
        await gate.release()
        _ = try await survivingWaiter.value
        #expect(await coordinator.isRefreshInProgress == false)
    }

    @Test("Subsequent coordinator runs a fresh refresh after a prior coordinator was released")
    func freshCoordinatorRunsRefreshAfterPriorWasReleased() async throws {
        // The detached refresh task captures `self` weakly. Even though
        // the awaiter on `refreshAndApply` keeps the coordinator alive
        // until that call returns, releasing the coordinator after a
        // completed refresh leaves no global state behind: a brand-new
        // coordinator with the same policy must run its own independent
        // refresh.
        actor RefreshCounter {
            private(set) var count: Int = 0
            func bump() { count += 1 }
        }
        let counter = RefreshCounter()
        let policy = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: {
                await counter.bump()
                return "new"
            }
        )
        let request = URLRequest(url: URL(string: "https://api.example.com/me")!)

        weak var weakFirstCoordinator: RefreshTokenCoordinator?
        do {
            let first = RefreshTokenCoordinator(policy: policy)
            weakFirstCoordinator = first
            _ = try await first.refreshAndApply(to: request)
        }
        #expect(weakFirstCoordinator == nil, "first coordinator should release after its refresh completes")

        let second = RefreshTokenCoordinator(policy: policy)
        _ = try await second.refreshAndApply(to: request)
        let observedCount = await counter.count
        #expect(observedCount == 2, "fresh coordinator must drive its own refresh — got \(observedCount)")
    }

    @Test("Refresh that throws CancellationError returns coordinator to idle, allowing a fresh restart")
    func cancelledRefreshReturnsToIdleAndPermitsRestart() async throws {
        actor InvocationLog {
            private(set) var attempts: Int = 0
            func bump() -> Int {
                attempts += 1
                return attempts
            }
        }
        let log = InvocationLog()
        let policy = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: {
                let attempt = await log.bump()
                if attempt == 1 {
                    // Simulate an upstream cancellation inside the refresh
                    // provider — the detached task body must funnel this
                    // through the actor's reducer and reset state to `.idle`
                    // before re-throwing, so the next caller is not blocked
                    // observing a stale `.inFlight` phase.
                    throw CancellationError()
                }
                return "new"
            }
        )
        let coordinator = RefreshTokenCoordinator(policy: policy)
        let request = URLRequest(url: URL(string: "https://api.example.com/me")!)

        await #expect(throws: CancellationError.self) {
            _ = try await coordinator.refreshAndApply(to: request)
        }

        // Once the cancelled refresh finishes, the coordinator must report
        // no in-flight refresh and must accept a new refresh that drives a
        // second `refreshTokenProvider` invocation — verifying the cancel
        // → idle → restart transition is wired end-to-end.
        #expect(await coordinator.isRefreshInProgress == false)

        let applied = try await coordinator.refreshAndApply(to: request)
        #expect(applied.value(forHTTPHeaderField: "Authorization") == "Bearer new")
        let attempts = await log.attempts
        #expect(attempts == 2, "second call must trigger a fresh refresh (got \(attempts) total)")
    }

    @Test("Coordinator deinit cancels orphaned in-flight refresh task")
    func coordinatorDeinitCancelsOrphanedInFlightRefresh() async throws {
        let probe = CancellableRefreshProbe()
        let policy = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: { try await probe.refreshToken() }
        )
        let request = URLRequest(url: URL(string: "https://api.example.com/me")!)

        weak var weakCoordinator: RefreshTokenCoordinator?
        let waiter: Task<URLRequest, Error>
        do {
            let coordinator = RefreshTokenCoordinator(policy: policy)
            weakCoordinator = coordinator
            waiter = Task {
                try await coordinator.refreshAndApply(to: request)
            }
        }

        await probe.waitUntilStarted()
        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await waiter.value
        }
        await probe.waitUntilCancelled()
        #expect(weakCoordinator == nil)
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
