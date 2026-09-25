import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

private actor ScopedCredentialProvider: OAuthCredentialRefreshing {
    let clock: TestClock
    let scopes: [String]?
    let expiry: Date?
    let renewedScopes: [String]?
    let changedIdentity: Bool
    let failsRefresh: Bool
    let holdsRefresh: Bool
    var refreshes = 0
    var selections = 0
    var renewed = false

    init(
        clock: TestClock, scopes: [String]? = ["Read"], expiry: Date? = Date(timeIntervalSince1970: 100),
        renewedScopes: [String]? = ["Read"], changedIdentity: Bool = false,
        failsRefresh: Bool = false, holdsRefresh: Bool = false
    ) {
        self.clock = clock
        self.scopes = scopes
        self.expiry = expiry
        self.renewedScopes = renewedScopes
        self.changedIdentity = changedIdentity
        self.failsRefresh = failsRefresh
        self.holdsRefresh = holdsRefresh
    }

    func select(alternatives: [[RequestSecurity.Scheme]], origin: URL) -> RequestSecurity.Selection {
        selections += 1
        return .init(alternative: 0, realm: "tenant", principal: "user")
    }

    func credential(for scheme: RequestSecurity.Scheme, selection: RequestSecurity.Selection, origin: URL)
        -> RequestSecurity.Credential
    {
        .init(
            value: renewed ? "fresh-token" : "old-token", realm: selection.realm, principal: selection.principal,
            grantedScopes: renewed ? renewedScopes : scopes,
            expiresAt: renewed ? clock.now().addingTimeInterval(100) : expiry)
    }

    func refreshCredential(for scheme: RequestSecurity.Scheme, selection: RequestSecurity.Selection, origin: URL)
        async throws -> RequestSecurity.Credential
    {
        refreshes += 1
        if holdsRefresh { try await clock.sleep(for: .seconds(1)) }
        if failsRefresh { throw NSError(domain: "secret-token", code: 1) }
        renewed = true
        return .init(
            value: "fresh-token", realm: selection.realm, principal: changedIdentity ? "other" : selection.principal,
            grantedScopes: renewedScopes, expiresAt: clock.now().addingTimeInterval(100))
    }
}

private struct ScopedCredentialEndpoint: APIDefinition, RequestSecurityProviding {
    typealias Parameter = EmptyParameter
    typealias APIResponse = EmptyResponse
    let requestSecurity: RequestSecurity
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var method: HTTPMethod = .get
    var path: String { "/scope" }
    var requestSigners: [any RequestSigner] = []
}

private struct ExpiringCredentialSigner: RequestSigner {
    let clock: TestClock
    func signatureHeaders(for request: URLRequest, body: RequestBody) async throws -> HTTPHeaders {
        clock.advance(by: .seconds(200))
        return ["X-Signed": "yes"]
    }
}

@Suite("Scoped OAuth credential boundary")
struct OAuthCredentialTests {
    private let origin = URL(string: "https://oauth.example")!
    private let scheme = RequestSecurity.Scheme.oauth2(id: "oauth", scopes: ["Read"])

    private func security(_ provider: any RequestCredentialProvider) throws -> RequestSecurity {
        try RequestSecurity(origin: origin, alternatives: [[scheme]], provider: provider)
    }

    private func client(_ session: MockURLSession, clock: TestClock) -> DefaultNetworkClient {
        DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: origin.absoluteString), session: session, clock: clock)
    }

    @Test("exact granted scopes and finite expiry are required", arguments: [0, 1, 2, 3, 4])
    func metadata(_ scenario: Int) async throws {
        let clock = TestClock()
        let provider = ScopedCredentialProvider(
            clock: clock, scopes: scenario == 0 ? nil : scenario == 1 ? ["read"] : ["Read"],
            expiry: scenario == 2
                ? nil : scenario == 3 ? Date(timeIntervalSince1970: .infinity) : clock.now().addingTimeInterval(100))
        let session = MockURLSession()
        session.setMockResponse(statusCode: 204)
        do {
            _ = try await client(session, clock: clock).request(
                ScopedCredentialEndpoint(requestSecurity: security(provider)))
            #expect(scenario == 4)
        } catch {
            #expect(scenario != 4)
            let expected: RequestSecurityFailure = scenario == 1 ? .insufficientScope : .scopeMetadataUnavailable
            #expect((error as? NetworkError)?.underlyingError?.code == expected.rawValue)
            #expect(session.capturedRequest == nil)
        }
        #expect(await provider.refreshes == 0)
    }

    @Test("expiry renews before dispatch; renewal preserves identity and scopes", arguments: [0, 1, 2, 3])
    func proactive(_ scenario: Int) async throws {
        let clock = TestClock()
        let provider = ScopedCredentialProvider(
            clock: clock, expiry: clock.now(), renewedScopes: scenario == 1 ? [] : ["Read"],
            changedIdentity: scenario == 2, failsRefresh: scenario == 3)
        let session = MockURLSession()
        session.setMockResponse(statusCode: 204)
        do {
            _ = try await client(session, clock: clock).request(
                ScopedCredentialEndpoint(requestSecurity: security(provider)))
            #expect(scenario == 0)
            #expect(session.capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
        } catch {
            #expect(scenario != 0)
            let expected: RequestSecurityFailure =
                scenario == 1 ? .insufficientScope : scenario == 2 ? .identityChanged : .refreshFailed
            #expect((error as? NetworkError)?.underlyingError?.code == expected.rawValue)
            #expect(!String(reflecting: error).contains("secret-token"))
            #expect(session.capturedRequest == nil)
        }
        #expect(await provider.refreshes == 1)
        #expect(await provider.selections == 1)
    }

    @Test("invalid_token replays GET once but never POST or insufficient_scope", arguments: [0, 1, 2, 3])
    func reactive(_ scenario: Int) async throws {
        let clock = TestClock()
        let provider = ScopedCredentialProvider(clock: clock)
        let session = MockURLSession()
        let challenge = scenario == 2 ? "Bearer error=insufficient_scope, scope=Admin" : "Bearer error=invalid_token"
        session.setScriptedResponses([
            .http(statusCode: scenario == 2 ? 403 : 401, headers: ["WWW-Authenticate": challenge]),
            .http(statusCode: scenario == 3 ? 401 : 204, headers: ["WWW-Authenticate": challenge]),
        ])
        do {
            _ = try await client(session, clock: clock).request(
                ScopedCredentialEndpoint(requestSecurity: security(provider), method: scenario == 1 ? .post : .get))
            #expect(scenario == 0)
        } catch {
            #expect(scenario != 0)
            #expect((error as? NetworkError)?.response?.statusCode == (scenario == 2 ? 403 : 401))
        }
        #expect(await provider.refreshes == (scenario == 0 || scenario == 3 ? 1 : 0))
        #expect(session.capturedRequestsInOrder.count == (scenario == 0 || scenario == 3 ? 2 : 1))
        if scenario == 0 {
            #expect(session.capturedRequestsInOrder[0].value(forHTTPHeaderField: "Authorization") == "Bearer old-token")
            #expect(
                session.capturedRequestsInOrder[1].value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
        }
    }

    @Test("expiry is checked again after an asynchronous signer")
    func expiresDuringSigning() async throws {
        let clock = TestClock()
        let provider = ScopedCredentialProvider(clock: clock)
        let session = MockURLSession()
        do {
            _ = try await client(session, clock: clock).request(
                ScopedCredentialEndpoint(
                    requestSecurity: security(provider), requestSigners: [ExpiringCredentialSigner(clock: clock)]))
            Issue.record("Expired signed token must not dispatch")
        } catch {
            #expect(
                (error as? NetworkError)?.underlyingError?.code == RequestSecurityFailure.credentialExpired.rawValue)
        }
        #expect(session.capturedRequest == nil)
    }

    @Test("proactive renewal consumes the same logical-request renewal budget")
    func oneRenewalBudget() async throws {
        let clock = TestClock()
        let provider = ScopedCredentialProvider(clock: clock, expiry: clock.now())
        let session = MockURLSession()
        session.setScriptedResponses([
            .http(statusCode: 401, headers: ["WWW-Authenticate": "Bearer error=invalid_token"])
        ])
        do {
            _ = try await client(session, clock: clock).request(
                ScopedCredentialEndpoint(requestSecurity: security(provider)))
            Issue.record("Second renewal must not hide the rejection")
        } catch { #expect((error as? NetworkError)?.response?.statusCode == 401) }
        #expect(await provider.refreshes == 1)
        #expect(session.capturedRequestsInOrder.count == 1)
    }

    @Test("overlapping renewals share identity but cancelled callers cannot cancel peers")
    func singleFlightCancellation() async throws {
        let clock = TestClock()
        let provider = ScopedCredentialProvider(clock: clock, expiry: clock.now(), holdsRefresh: true)
        let security = try security(provider)
        let session = MockURLSession()
        session.setMockResponse(statusCode: 204)
        let client = client(session, clock: clock)
        let first = Task { try await client.request(ScopedCredentialEndpoint(requestSecurity: security)) }
        let second = Task { try await client.request(ScopedCredentialEndpoint(requestSecurity: security)) }
        defer {
            first.cancel()
            second.cancel()
            clock.advance(by: .seconds(1))
        }
        try await waitForWaiters(2, coordinator: security.oauthRefreshes)
        first.cancel()
        do {
            _ = try await first.value
            Issue.record("Cancelled waiter succeeded")
        } catch { #expect(NetworkError.isCancellation(error)) }
        #expect(await provider.refreshes == 1)
        clock.advance(by: .seconds(1))
        _ = try await second.value
        #expect(session.capturedRequestsInOrder.count == 1)
        #expect(await security.oauthRefreshes.inFlightWaiterCount == 0)
    }

    @Test("all cancelled waiters release their provider; different scopes and identities never join")
    func refreshIsolation() async throws {
        let clock = TestClock()
        let coordinator = OAuthCredentialRefreshCoordinator()
        let selections: [RequestSecurity.Selection] = [
            .init(alternative: 0, realm: "a", principal: "user"),
            .init(alternative: 0, realm: "b", principal: "user"),
            .init(alternative: 0, realm: "a", principal: "other"),
            .init(alternative: 0, realm: "a", principal: "user"),
        ]
        let tasks = selections.enumerated().map { index, selection in
            Task {
                try await coordinator.refresh(
                    scheme: .oauth2(id: "oauth", scopes: index == 3 ? ["Write"] : ["Read"]), selection: selection
                ) {
                    try await clock.sleep(for: .seconds(10))
                    return .init(value: "token", realm: selection.realm, principal: selection.principal)
                }
            }
        }
        defer {
            tasks.forEach { $0.cancel() }
            clock.advance(by: .seconds(10))
        }
        try await waitForWaiters(4, coordinator: coordinator)
        #expect(await clock.waitForEnqueuedCount(atLeast: 4))
        tasks.forEach { $0.cancel() }
        for task in tasks {
            do {
                _ = try await task.value
                Issue.record("Cancelled refresh succeeded")
            } catch { #expect(NetworkError.isCancellation(error)) }
        }
        #expect(await coordinator.inFlightWaiterCount == 0)
    }

    @Test("challenge parsing ignores quoted tricks, duplicates and combined challenges")
    func challenges() {
        #expect(OAuthBearerChallenge.error(in: "Bearer realm=example, error=invalid_token") == "invalid_token")
        #expect(OAuthBearerChallenge.error(in: "bEaReR error=\"invalid_token\"") == "invalid_token")
        for header in [
            "Basic error=invalid_token", "Bearer realm=\"error=invalid_token\"",
            "Bearer error=invalid_token, error=insufficient_scope", "Bearer error=invalid_token, Basic realm=x",
            "Bearer error=invalid_token,", "Bearer error=\"invalid_token", "Bearer error=invalid_token\r\nX: y",
            String(repeating: "x", count: 8193),
        ] { #expect(OAuthBearerChallenge.error(in: header) == nil) }
    }

    @Test("renewal groups and waiters are bounded", arguments: [true, false])
    func refreshBounds(_ separateGroups: Bool) async throws {
        let clock = TestClock()
        let coordinator = OAuthCredentialRefreshCoordinator()
        let count = separateGroups ? 64 : 128
        let tasks = (0..<count).map { index in
            let selection = RequestSecurity.Selection(
                alternative: 0, realm: "tenant", principal: separateGroups ? "user-\(index)" : "user")
            return Task {
                try await coordinator.refresh(scheme: scheme, selection: selection) {
                    try await clock.sleep(for: .seconds(100))
                    return .init(value: "token", realm: selection.realm, principal: selection.principal)
                }
            }
        }
        defer {
            tasks.forEach { $0.cancel() }
            clock.advance(by: .seconds(100))
        }
        try await waitForWaiters(count, coordinator: coordinator)
        do {
            _ = try await coordinator.refresh(
                scheme: scheme,
                selection: .init(alternative: 0, realm: "tenant", principal: separateGroups ? "overflow" : "user")
            ) {
                Issue.record("Over-budget provider must not start")
                return .init(value: "token", realm: "tenant", principal: "user")
            }
            Issue.record("Over-budget renewal succeeded")
        } catch {
            #expect((error as? NetworkError)?.underlyingError?.code == RequestSecurityFailure.refreshFailed.rawValue)
        }
        tasks.forEach { $0.cancel() }
        for task in tasks { _ = await task.result }
        #expect(await coordinator.inFlightWaiterCount == 0)
    }

    @Test("invalid scope and colliding bearer contracts fail at construction")
    func invalidContracts() {
        let provider = ScopedCredentialProvider(clock: TestClock())
        for scopes in [["read write"], ["Read", "Read"], [""], Array(repeating: "x", count: 65)] {
            #expect(throws: RequestSecurityFailure.invalidRequirements) {
                try RequestSecurity(
                    origin: origin, alternatives: [[.oauth2(id: "oauth", scopes: scopes)]], provider: provider)
            }
        }
        #expect(throws: RequestSecurityFailure.invalidRequirements) {
            try RequestSecurity(origin: origin, alternatives: [[scheme, .bearer(id: "other")]], provider: provider)
        }
    }

    private func waitForWaiters(_ count: Int, coordinator: OAuthCredentialRefreshCoordinator) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await coordinator.inFlightWaiterCount < count {
            try #require(ContinuousClock.now < deadline, "Refresh waiters did not register")
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
