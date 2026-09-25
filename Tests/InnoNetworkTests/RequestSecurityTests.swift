import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

private actor CredentialProviderFixture: RequestCredentialProvider {
    var selections = 0
    var acquisitions: [String] = []
    let alternative: Int
    let failedScheme: String?
    let changedIdentity: Bool
    let value: String

    init(
        alternative: Int = 0, failedScheme: String? = nil, changedIdentity: Bool = false,
        value: String = "fixture-secret"
    ) {
        self.alternative = alternative
        self.failedScheme = failedScheme
        self.changedIdentity = changedIdentity
        self.value = value
    }

    func select(alternatives: [[RequestSecurity.Scheme]], origin: URL) async throws -> RequestSecurity.Selection {
        selections += 1
        return .init(alternative: alternative, realm: "tenant", principal: "user")
    }

    func credential(for scheme: RequestSecurity.Scheme, selection: RequestSecurity.Selection, origin: URL) async throws
        -> RequestSecurity.Credential
    {
        acquisitions.append(scheme.id)
        if scheme.id == failedScheme {
            throw NSError(domain: "Provider", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture-secret"])
        }
        return .init(
            value: value, realm: selection.realm, principal: changedIdentity ? "other-user" : selection.principal)
    }
}

private struct CredentialReceipt: Decodable, Sendable {
    let responseURL: URL?
    let requestCredential: String?
}

private struct CredentialEndpoint: APIDefinition, RequestSecurityProviding {
    typealias Parameter = EmptyParameter
    typealias APIResponse = CredentialReceipt
    let requestSecurity: RequestSecurity
    var sessionAuthentication: SessionAuthentication = .anonymous
    var headers: HTTPHeaders = [:]
    var path: String = "/secured"
    var requestSigners: [RequestSigner] = []
    var requestInterceptors: [RequestInterceptor] = []
    var method: HTTPMethod { .get }
    var transport: TransportPolicy<CredentialReceipt> {
        .custom(encoding: .json(defaultRequestEncoder)) { _, response in
            CredentialReceipt(
                responseURL: response.response?.url,
                requestCredential: response.request?.value(forHTTPHeaderField: "X-Custom-Credential"))
        }
    }
}

private struct CredentialInspectingSigner: RequestSigner {
    var overwrite = false
    func signatureHeaders(for request: URLRequest, body: RequestBody) async throws -> HTTPHeaders {
        #expect(request.value(forHTTPHeaderField: "X-Custom-Credential") == "fixture-secret")
        #expect(request.value(forHTTPHeaderField: "Cache-Control")?.contains("no-store") == true)
        return overwrite ? ["X-Custom-Credential": "replaced"] : ["X-Signed": "yes"]
    }
}

private struct CredentialOriginInterceptor: RequestInterceptor {
    func adapt(_ request: URLRequest) async throws -> URLRequest {
        var result = request
        result.url = URL(string: "https://other.example/secured")!
        return result
    }
}

private actor CredentialTransport: URLSessionProtocol {
    var requests: [URLRequest] = []
    var contexts: [NetworkRequestContext] = []
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return (
            Data(),
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Cache-Control": "max-age=60"])!
        )
    }
    func data(for request: URLRequest, context: NetworkRequestContext) async throws -> (Data, URLResponse) {
        contexts.append(context)
        return try await data(for: request)
    }
}

@Suite("Origin-bound credential execution")
struct RequestSecurityTests {
    private let origin = URL(string: "https://api.example.com")!
    private let key = RequestSecurity.Scheme.apiKey(id: "key", name: "X-Custom-Credential", location: .header)

    private func security(_ provider: any RequestCredentialProvider, alternatives: [[RequestSecurity.Scheme]]? = nil)
        throws -> RequestSecurity
    {
        try RequestSecurity(origin: origin, alternatives: alternatives ?? [[key]], provider: provider)
    }

    private func client(_ session: any URLSessionProtocol) -> DefaultNetworkClient {
        DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: origin.absoluteString), session: session)
    }

    private func expectFailure(
        _ endpoint: CredentialEndpoint, code: RequestSecurityFailure, session: MockURLSession = MockURLSession()
    ) async {
        do {
            _ = try await client(session).request(endpoint)
            Issue.record("Expected a credential-boundary failure")
        } catch {
            #expect(error.underlyingError?.domain == "InnoNetwork.RequestSecurity")
            #expect(error.underlyingError?.code == code.rawValue)
            #expect(!String(reflecting: error).contains("fixture-secret"))
        }
        #expect(session.capturedRequest == nil)
    }

    @Test("credentials precede configuration and endpoint signers; public response has no credential")
    func signing() async throws {
        let provider = CredentialProviderFixture()
        let session = MockURLSession()
        session.setMockResponse(statusCode: 200)
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: origin.absoluteString, requestSigners: [CredentialInspectingSigner()]), session: session)
        let response = try await client.request(
            CredentialEndpoint(requestSecurity: security(provider), requestSigners: [CredentialInspectingSigner()]))
        #expect(session.capturedRequest?.value(forHTTPHeaderField: "X-Signed") == "yes")
        #expect(response.requestCredential == nil)
        #expect(await provider.selections == 1)
    }

    @Test("origin changes fail before asking for credentials")
    func originBinding() async throws {
        let provider = CredentialProviderFixture()
        await expectFailure(
            CredentialEndpoint(
                requestSecurity: try security(provider), requestInterceptors: [CredentialOriginInterceptor()]),
            code: .originMismatch)
        #expect(await provider.acquisitions.isEmpty)
    }

    @Test("legacy session auth cannot overlap")
    func legacyConflict() async throws {
        await expectFailure(
            CredentialEndpoint(
                requestSecurity: try security(CredentialProviderFixture()), sessionAuthentication: .optional),
            code: .unsupportedExecution)
    }

    @Test("AND is atomic and never falls back to an anonymous alternative")
    func atomicAND() async throws {
        let provider = CredentialProviderFixture(failedScheme: "bearer")
        await expectFailure(
            CredentialEndpoint(
                requestSecurity: try security(provider, alternatives: [[key, .bearer(id: "bearer")], []])),
            code: .credentialUnavailable)
        #expect(await provider.acquisitions == ["key", "bearer"])
        #expect(await provider.selections == 1)
    }

    @Test("OR selection is explicit, including anonymous")
    func explicitSelection() async throws {
        let provider = CredentialProviderFixture(alternative: 1)
        let session = MockURLSession()
        session.setMockResponse(statusCode: 200)
        _ = try await client(session).request(
            CredentialEndpoint(requestSecurity: security(provider, alternatives: [[key], []])))
        #expect(session.capturedRequest?.value(forHTTPHeaderField: "X-Custom-Credential") == nil)
        #expect(await provider.acquisitions.isEmpty)
        await expectFailure(
            CredentialEndpoint(requestSecurity: try security(CredentialProviderFixture(alternative: 2))),
            code: .selectionFailed)
    }

    @Test("identity changes and credential overwrites are rejected")
    func identityAndCollision() async throws {
        await expectFailure(
            CredentialEndpoint(requestSecurity: try security(CredentialProviderFixture(changedIdentity: true))),
            code: .identityChanged)
        let provider = CredentialProviderFixture()
        await expectFailure(
            CredentialEndpoint(requestSecurity: try security(provider), headers: ["x-custom-credential": "caller"]),
            code: .credentialConflict)
        #expect(await provider.acquisitions.isEmpty)
        await expectFailure(
            CredentialEndpoint(
                requestSecurity: try security(provider), requestSigners: [CredentialInspectingSigner(overwrite: true)]),
            code: .credentialConflict)
    }

    @Test(
        "query and cookie placement is explicit and custom VCR names are automatically redacted",
        arguments: [RequestSecurity.Location.header, .query, .cookie])
    func placementAndVCR(_ location: RequestSecurity.Location) async throws {
        let provider = CredentialProviderFixture()
        let declaration = RequestSecurity.Scheme.apiKey(id: "key", name: "unusualCredential", location: location)
        if location != .header {
            #expect(throws: RequestSecurityFailure.invalidRequirements) {
                try RequestSecurity(origin: origin, alternatives: [[declaration]], provider: provider)
            }
        }
        let security = try RequestSecurity(
            origin: origin, alternatives: [[declaration]], provider: provider, allowsQueryCredentials: true,
            allowsCookieCredentials: true)
        let backing = MockURLSession()
        backing.setMockResponse(statusCode: 200, data: Data("{}".utf8))
        let vcr = VCRURLSession(mode: .record, recordingSession: backing)
        _ = try await client(vcr).request(CredentialEndpoint(requestSecurity: security))
        let request = try #require(backing.capturedRequest)
        switch location {
        case .header: #expect(request.value(forHTTPHeaderField: "unusualCredential") == "fixture-secret")
        case .query: #expect(request.url?.query == "unusualCredential=fixture-secret")
        case .cookie: #expect(request.value(forHTTPHeaderField: "Cookie") == "unusualCredential=fixture-secret")
        }
        let serialized = String(decoding: try JSONEncoder().encode(vcr.cassette), as: UTF8.self)
        #expect(!serialized.contains("fixture-secret"))
        #expect(serialized.contains("redacted"))
        let replay = VCRURLSession(cassette: vcr.cassette, mode: .replay)
        _ = try await client(replay).request(CredentialEndpoint(requestSecurity: security))
    }

    @Test("credential requests bypass sharing, URLCache and automatic redirects")
    func isolation() async throws {
        let session = CredentialTransport()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: origin.absoluteString, requestCoalescingPolicy: .getOnly,
                responseCachePolicy: .cacheFirst(maxAge: .seconds(60)), responseCache: InMemoryResponseCache()),
            session: session)
        let endpoint = CredentialEndpoint(requestSecurity: try security(CredentialProviderFixture()))
        async let first = client.request(endpoint)
        async let second = client.request(endpoint)
        _ = try await (first, second)
        _ = try await client.request(endpoint)
        #expect(await session.requests.count == 3)
        let contexts = await session.contexts
        #expect(contexts.allSatisfy { !$0.allowsAutomaticRedirects && !$0.allowsURLCacheStorage })
        #expect(await session.requests.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalCacheData })
    }

    @Test("query credentials are removed from returned HTTP metadata")
    func responseMetadata() async throws {
        let security = try RequestSecurity(
            origin: origin, alternatives: [[.apiKey(id: "key", name: "custom", location: .query)]],
            provider: CredentialProviderFixture(), allowsQueryCredentials: true)
        let response = try await client(CredentialTransport()).request(CredentialEndpoint(requestSecurity: security))
        #expect(response.responseURL?.absoluteString.contains("fixture-secret") == false)
        #expect(response.responseURL?.absoluteString.contains("redacted") == true)
    }

    @Test("selection remains fixed across retry while the provider reacquires credentials")
    func retryIdentity() async throws {
        let provider = CredentialProviderFixture()
        let session = MockURLSession()
        session.setScriptedResponses([.http(statusCode: 503), .http(statusCode: 200)])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: origin.absoluteString, retryPolicy: ExponentialBackoffRetryPolicy(maxRetries: 1, retryDelay: 0)
            ), session: session)
        _ = try await client.request(CredentialEndpoint(requestSecurity: security(provider)))
        #expect(await provider.selections == 1)
        #expect(await provider.acquisitions.count == 2)
    }

    @Test("invalid names, values and origin metadata fail closed")
    func invalidInputs() async throws {
        for name in ["Host", "Cookie", "Content-Length", "Connection", "Idempotency-Key", "X\r\nInjected"] {
            #expect(throws: RequestSecurityFailure.invalidRequirements) {
                try RequestSecurity(
                    origin: origin, alternatives: [[.apiKey(id: "key", name: name, location: .header)]],
                    provider: CredentialProviderFixture())
            }
        }
        for raw in [
            "http://api.example.com", "https://user:pass@api.example.com", "https://api.example.com/path",
            "https://api.example.com?token=a", "https://api.example.com#part",
        ] {
            #expect(throws: RequestSecurityFailure.invalidRequirements) {
                try RequestSecurity(
                    origin: URL(string: raw)!, alternatives: [[key]], provider: CredentialProviderFixture())
            }
        }
        for value in ["", "a\r\nb", String(repeating: "a", count: 8193)] {
            await expectFailure(
                CredentialEndpoint(requestSecurity: try security(CredentialProviderFixture(value: value))),
                code: .credentialUnavailable)
        }
        #expect(throws: RequestSecurityFailure.invalidRequirements) {
            try security(CredentialProviderFixture(), alternatives: [[.bearer(id: "a"), .bearer(id: "b")]])
        }
        #expect(throws: RequestSecurityFailure.invalidRequirements) {
            try security(CredentialProviderFixture(), alternatives: Array(repeating: [], count: 33))
        }
    }

    @Test("credential failures are not automatically retried as transport failures")
    func noCredentialRetry() async throws {
        let provider = CredentialProviderFixture(failedScheme: "key")
        let session = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: origin.absoluteString, retryPolicy: ExponentialBackoffRetryPolicy(maxRetries: 2, retryDelay: 0)
            ), session: session)
        let endpoint = CredentialEndpoint(requestSecurity: try security(provider, alternatives: [[key], []]))
        do {
            _ = try await client.request(endpoint)
            Issue.record("Expected credential failure")
        } catch {
            let failure = NetworkFailure(migratingV5: error)
            #expect(failure.kind == .configuration)
            #expect(failure.recovery == .doNotRetry)
        }
        #expect(await provider.selections == 1)
        #expect(await provider.acquisitions == ["key"])
        #expect(session.capturedRequest == nil)
    }

    @Test("cancellation after a non-cooperating provider never dispatches")
    func cancellation() async throws {
        actor SuspendedProvider: RequestCredentialProvider {
            var started = false
            var continuation: CheckedContinuation<Void, Never>?
            func select(alternatives: [[RequestSecurity.Scheme]], origin: URL) -> RequestSecurity.Selection {
                .init(alternative: 0, realm: "tenant", principal: "user")
            }
            func credential(for scheme: RequestSecurity.Scheme, selection: RequestSecurity.Selection, origin: URL) async
                -> RequestSecurity.Credential
            {
                started = true
                await withCheckedContinuation { continuation = $0 }
                return .init(value: "fixture-secret", realm: "tenant", principal: "user")
            }
            func release() {
                continuation?.resume()
                continuation = nil
            }
        }
        let provider = SuspendedProvider()
        let session = MockURLSession()
        let endpoint = CredentialEndpoint(requestSecurity: try security(provider))
        let task = Task { try await client(session).request(endpoint) }
        while !(await provider.started) { await Task.yield() }
        task.cancel()
        await provider.release()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch { #expect(NetworkError.isCancellation(error)) }
        #expect(session.capturedRequest == nil)
    }

    @Test("queued requests select identity early but acquire secrets only after admission")
    func acquisitionAfterAdmission() async throws {
        let clock = TestClock()
        let configuration = NetworkConfiguration(
            baseURL: origin, networkMonitor: nil,
            requestAdmissionPolicy: RequestAdmissionPolicy(
                maximumConcurrentRequests: 1, maximumPendingRequests: 1, maximumQueueWait: .seconds(30)))
        let runtime = RequestExecutionRuntime(configuration: configuration, inFlight: InFlightRegistry(), clock: clock)
        let blocker = try #require(try await runtime.requestAdmission?.acquire(for: URLRequest(url: origin)))
        let provider = CredentialProviderFixture()
        let session = MockURLSession()
        session.setMockResponse(statusCode: 200)
        let hub = NetworkEventHub()
        let endpoint = CredentialEndpoint(requestSecurity: try security(provider))
        let task = Task {
            try await RequestExecutor(session: session, eventHub: hub).execute(
                APISingleRequestExecutable(base: endpoint), configuration: configuration,
                requestBuilder: RequestBuilder(), runtime: runtime, retryIndex: 0, requestID: UUID())
        }
        #expect(await clock.waitForWaiters(count: 1))
        #expect(await provider.selections == 1)
        #expect(await provider.acquisitions.isEmpty)
        await runtime.requestAdmission?.release(scope: blocker.scope)
        _ = try await task.value
        #expect(await provider.acquisitions == ["key"])
        #expect(await runtime.requestAdmission?.snapshot.active == 0)
        await hub.shutdown()
        await runtime.shutdown()
    }

    @Test("multipart supports the boundary, while streaming rejects it before selecting credentials")
    func executionSurfaces() async throws {
        struct Upload: MultipartAPIDefinition, RequestSecurityProviding {
            typealias APIResponse = EmptyResponse
            let requestSecurity: RequestSecurity
            let multipartFormData = MultipartFormData()
            var method: HTTPMethod { .post }
            var path: String { "/upload" }
            var sessionAuthentication: SessionAuthentication { .anonymous }
            var uploadStrategy: MultipartUploadStrategy { .inMemory(maxBytes: 1024) }
        }
        struct Stream: StreamingAPIDefinition, RequestSecurityProviding {
            let requestSecurity: RequestSecurity
            var method: HTTPMethod { .get }
            var path: String { "/stream" }
            var sessionAuthentication: SessionAuthentication { .anonymous }
            func decode(line: String) -> String? { line }
        }
        let provider = CredentialProviderFixture()
        let declaration = try security(provider)
        let session = MockURLSession()
        session.setMockResponse(statusCode: 204)
        _ = try await client(session).upload(Upload(requestSecurity: declaration))
        #expect(session.capturedRequest?.value(forHTTPHeaderField: "X-Custom-Credential") == "fixture-secret")
        let before = await provider.selections
        let streamingClient = client(session)
        var iterator = streamingClient.stream(Stream(requestSecurity: declaration)).makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("Expected unsupported streaming")
        } catch {
            #expect(
                error.underlyingError?.code == RequestSecurityFailure.unsupportedExecution.rawValue)
        }
        #expect(await provider.selections == before)
    }

    @Test("transport error metadata cannot echo credentials and retains retry classification")
    func transportErrors() async throws {
        let session = MockURLSession()
        session.mockError = URLError(
            .networkConnectionLost,
            userInfo: [NSLocalizedDescriptionKey: "fixture-secret", NSLocalizedFailureReasonErrorKey: "fixture-secret"])
        do {
            _ = try await client(session).request(
                CredentialEndpoint(requestSecurity: security(CredentialProviderFixture())))
            Issue.record("Expected transport failure")
        } catch {
            guard case .reachability(.networkConnectionLost, _, _) = error as? NetworkError else {
                Issue.record("Lost transport classification")
                return
            }
            #expect(!String(reflecting: error).contains("fixture-secret"))
        }
    }

    @Test("native session default auth headers cannot add or replace the selected identity")
    func sessionHeaderConflict() async throws {
        for header in ["Authorization", "Cookie", "x-custom-credential"] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpAdditionalHeaders = [header: "session-secret"]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let client = DefaultNetworkClient(
                configuration: makeTestNetworkConfiguration(baseURL: origin.absoluteString), session: session)
            let endpoint = CredentialEndpoint(requestSecurity: try security(CredentialProviderFixture()))
            do {
                _ = try await client.request(endpoint)
                Issue.record("Expected session-header conflict")
            } catch {
                #expect(error.underlyingError?.domain == "InnoNetwork.RequestSecurity")
                #expect(error.underlyingError?.code == RequestSecurityFailure.credentialConflict.rawValue)
                #expect(!String(reflecting: error).contains("session-secret"))
            }
        }
    }

    @Test("cookie AND assembles only selected cookies and query collisions include percent-encoded names")
    func cookieANDAndQueryCollision() async throws {
        let provider = CredentialProviderFixture()
        let cookies = try RequestSecurity(
            origin: origin,
            alternatives: [
                [
                    .apiKey(id: "a", name: "a", location: .cookie), .apiKey(id: "b", name: "b", location: .cookie),
                ]
            ], provider: provider, allowsCookieCredentials: true)
        let session = MockURLSession()
        session.setMockResponse(statusCode: 200)
        _ = try await client(session).request(CredentialEndpoint(requestSecurity: cookies))
        #expect(session.capturedRequest?.value(forHTTPHeaderField: "Cookie") == "a=fixture-secret; b=fixture-secret")
        #expect(session.capturedRequest?.httpShouldHandleCookies == false)
        let query = try RequestSecurity(
            origin: origin, alternatives: [[.apiKey(id: "q", name: "custom", location: .query)]], provider: provider,
            allowsQueryCredentials: true)
        let prepared = try await RequestSecurityExecution(query).prepare(for: URLRequest(url: origin))
        await #expect(throws: NetworkError.self) {
            try await prepared.apply(to: URLRequest(url: URL(string: "https://api.example.com/?cu%73tom=caller")!))
        }
    }
}
