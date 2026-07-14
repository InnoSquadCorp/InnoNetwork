import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork

private final class SigningTrace: Sendable {
    private struct State {
        var events: [String] = []
        var observedRequests: [URLRequest] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func record(_ event: String, request: URLRequest? = nil) {
        lock.withLock { state in
            state.events.append(event)
            if let request {
                state.observedRequests.append(request)
            }
        }
    }

    var events: [String] { lock.withLock { $0.events } }
    var observedRequests: [URLRequest] { lock.withLock { $0.observedRequests } }
}

private struct PipelineStampingInterceptor: RequestInterceptor {
    let trace: SigningTrace

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        trace.record("interceptor")
        var request = urlRequest
        request.setValue("adapted", forHTTPHeaderField: "X-Adapted")
        return request
    }
}

private struct ConditionalValidatorInterceptor: RequestInterceptor {
    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue("v1", forHTTPHeaderField: "If-None-Match")
        return request
    }
}

private struct PipelineSigner: RequestSigner {
    let label: String
    let trace: SigningTrace

    func signatureHeaders(for request: URLRequest, body: RequestBody) async throws -> HTTPHeaders {
        _ = body
        trace.record("signer:\(label)", request: request)
        let prefix = request.value(forHTTPHeaderField: "X-Signer-Order")
        let value = [prefix, label].compactMap { $0 }.joined(separator: ",")
        return ["X-Signer-Order": value]
    }
}

private struct SignerPipelineEndpoint: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = SignerPipelineResponse

    var method: HTTPMethod { .get }
    var path: String { "/signed" }

    let endpointSigners: [RequestSigner]
    var requestSigners: [RequestSigner] { endpointSigners }
}

private struct SignerPipelineResponse: Codable, Sendable, Equatable {
    let value: String
}

private actor CountingVolatileSigner: RequestSigner {
    private var count = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func signatureHeaders(for request: URLRequest, body: RequestBody) async throws -> HTTPHeaders {
        _ = (request, body)
        count += 1
        let current = count
        let ready = waiters.filter { current >= $0.target }
        waiters.removeAll { current >= $0.target }
        ready.forEach { $0.continuation.resume() }
        return ["X-Volatile-Signature": "signature-\(current)"]
    }

    func waitForInvocations(_ target: Int) async {
        guard count < target else { return }
        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }

    var invocationCount: Int { count }
}

private actor BlockingSigningSession: URLSessionProtocol {
    private var requests: [URLRequest] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var requestCountWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var isReleased = false

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let ready = requestCountWaiters.filter { requests.count >= $0.target }
        requestCountWaiters.removeAll { requests.count >= $0.target }
        ready.forEach { $0.continuation.resume() }
        if !isReleased {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        let data = try JSONEncoder().encode(SignerPipelineResponse(value: "network"))
        return (
            data,
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitForRequests(_ target: Int) async {
        guard requests.count < target else { return }
        await withCheckedContinuation { continuation in
            requestCountWaiters.append((target, continuation))
        }
    }

    var requestCount: Int { requests.count }
}

private actor PrincipalAwareSigningSession: URLSessionProtocol {
    private var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let principal = request.value(forHTTPHeaderField: "Authorization") ?? "anonymous"
        let data = try JSONEncoder().encode(SignerPipelineResponse(value: principal))
        return (
            data,
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    var requestCount: Int { requests.count }
}

private final class PrincipalCacheURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var capturedStorage: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        capturedStorage.removeAll()
        lock.unlock()
    }

    static var capturedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedStorage
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        Self.capturedStorage.append(request)
        Self.lock.unlock()

        do {
            let principal = request.value(forHTTPHeaderField: "Authorization") ?? "anonymous"
            let data = try JSONEncoder().encode(SignerPipelineResponse(value: principal))
            guard
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Cache-Control": "max-age=600",
                        "Content-Length": "\(data.count)",
                        "Content-Type": "application/json",
                    ]
                )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

@Suite("Late request signer pipeline")
struct RequestSignerPipelineTests {
    @Test("JWT bearer provider observes refresh-token adaptation and intentionally wins as the later auth header")
    func jwtBearerUsesLateAuthHeaderContract() async throws {
        let session = MockURLSession()
        try session.setMockJSON(SignerPipelineResponse(value: "network"))
        let refresh = RefreshTokenPolicy(
            currentToken: { "current-token" },
            refreshToken: { "refreshed-token" }
        )
        let jwt = JWTBearerInterceptor { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer current-token"
                ? "minted-after-refresh"
                : "wrong-order"
        }
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                requestSigners: [jwt],
                refreshTokenPolicy: refresh
            ),
            session: session
        )

        _ = try await client.request(SignerPipelineEndpoint(endpointSigners: []))

        #expect(
            session.capturedRequest?.value(forHTTPHeaderField: "Authorization")
                == "Bearer minted-after-refresh"
        )
    }

    @Test("Signers run after interceptors and current-token adaptation in configuration-to-endpoint order")
    func orderingContract() async throws {
        let trace = SigningTrace()
        let session = MockURLSession()
        try session.setMockJSON(SignerPipelineResponse(value: "network"))
        let refresh = RefreshTokenPolicy(
            currentToken: { "current-token" },
            refreshToken: { "refreshed-token" }
        )
        let configuration = makeTestNetworkConfiguration(
            baseURL: "https://api.example.com/v1",
            requestInterceptors: [PipelineStampingInterceptor(trace: trace)],
            requestSigners: [PipelineSigner(label: "configuration", trace: trace)],
            refreshTokenPolicy: refresh
        )
        let client = DefaultNetworkClient(configuration: configuration, session: session)

        _ = try await client.request(
            SignerPipelineEndpoint(
                endpointSigners: [PipelineSigner(label: "endpoint", trace: trace)]
            )
        )

        #expect(trace.events == ["interceptor", "signer:configuration", "signer:endpoint"])
        let firstSignerRequest = try #require(trace.observedRequests.first)
        #expect(firstSignerRequest.value(forHTTPHeaderField: "X-Adapted") == "adapted")
        #expect(firstSignerRequest.value(forHTTPHeaderField: "Authorization") == "Bearer current-token")
        #expect(session.capturedRequest?.value(forHTTPHeaderField: "X-Signer-Order") == "configuration,endpoint")
    }

    @Test("A refresh-token replay is signed again after the refreshed token is applied")
    func refreshReplayResigns() async throws {
        let trace = SigningTrace()
        let session = MockURLSession()
        let body = try JSONEncoder().encode(SignerPipelineResponse(value: "network"))
        session.setScriptedResponses([
            .http(statusCode: 401),
            .http(statusCode: 200, data: body),
        ])
        let refresh = RefreshTokenPolicy(
            currentToken: { "current-token" },
            refreshToken: { "refreshed-token" }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                requestSigners: [PipelineSigner(label: "signature", trace: trace)],
                refreshTokenPolicy: refresh
            ),
            session: session
        )

        _ = try await client.request(SignerPipelineEndpoint(endpointSigners: []))

        #expect(trace.observedRequests.count == 2)
        #expect(trace.observedRequests[0].value(forHTTPHeaderField: "Authorization") == "Bearer current-token")
        #expect(trace.observedRequests[1].value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-token")
        #expect(session.capturedRequestsInOrder.count == 2)
    }

    @Test("All interceptor-provided pre-transport headers are present before the signer runs")
    func preTransportHeadersAreSigned() async throws {
        let trace = SigningTrace()
        let session = MockURLSession()
        try session.setMockJSON(SignerPipelineResponse(value: "network"))
        let configuration = makeTestNetworkConfiguration(
            baseURL: "https://api.example.com/v1",
            requestInterceptors: [ConditionalValidatorInterceptor()],
            requestSigners: [PipelineSigner(label: "signature", trace: trace)]
        )
        let client = DefaultNetworkClient(configuration: configuration, session: session)

        _ = try await client.request(SignerPipelineEndpoint(endpointSigners: []))

        #expect(trace.observedRequests.count == 1)
        #expect(trace.observedRequests[0].value(forHTTPHeaderField: "If-None-Match") == "v1")
    }

    @Test("Signed requests bypass response sharing until a stable principal identity contract exists")
    func signedRequestsBypassResponseCache() async throws {
        let signer = CountingVolatileSigner()
        let session = MockURLSession()
        try session.setMockJSON(SignerPipelineResponse(value: "network"))
        let configuration = makeTestNetworkConfiguration(
            baseURL: "https://api.example.com/v1",
            requestSigners: [signer],
            responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
            responseCache: InMemoryResponseCache()
        )
        let client = DefaultNetworkClient(configuration: configuration, session: session)
        let endpoint = SignerPipelineEndpoint(endpointSigners: [])

        _ = try await client.request(endpoint)
        _ = try await client.request(endpoint)

        #expect(await signer.invocationCount == 2)
        #expect(session.capturedRequestsInOrder.count == 2)
    }

    @Test("Signed requests do not coalesce under an unsigned identity")
    func signedRequestsDoNotCoalesce() async throws {
        let signer = CountingVolatileSigner()
        let session = BlockingSigningSession()
        let configuration = makeTestNetworkConfiguration(
            baseURL: "https://api.example.com/v1",
            requestSigners: [signer],
            requestCoalescingPolicy: .getOnly
        )
        let client = DefaultNetworkClient(configuration: configuration, session: session)
        let endpoint = SignerPipelineEndpoint(endpointSigners: [])

        let first = Task { try await client.request(endpoint) }
        let second = Task { try await client.request(endpoint) }
        await signer.waitForInvocations(2)
        await session.waitForRequests(2)

        #expect(await session.requestCount == 2)
        await session.release()
        _ = try await first.value
        _ = try await second.value
        #expect(await session.requestCount == 2)
    }

    @Test("Different endpoint signer principals cannot reuse one another's cached response")
    func endpointSignerPrincipalsStayIsolated() async throws {
        let session = PrincipalAwareSigningSession()
        let configuration = makeTestNetworkConfiguration(
            baseURL: "https://api.example.com/v1",
            responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
            responseCache: InMemoryResponseCache()
        )
        let client = DefaultNetworkClient(configuration: configuration, session: session)
        let principalA = JWTBearerInterceptor { _ in "principal-a" }
        let principalB = JWTBearerInterceptor { _ in "principal-b" }

        let first = try await client.request(
            SignerPipelineEndpoint(endpointSigners: [principalA])
        )
        let second = try await client.request(
            SignerPipelineEndpoint(endpointSigners: [principalB])
        )

        #expect(first.value == "Bearer principal-a")
        #expect(second.value == "Bearer principal-b")
        #expect(await session.requestCount == 2)
    }

    @Test("Signed principals bypass URLSession's protocol cache even without Vary")
    func endpointSignerPrincipalsBypassURLSessionCache() async throws {
        PrincipalCacheURLProtocol.reset()
        let cache = URLCache(memoryCapacity: 1_024 * 1_024, diskCapacity: 0)
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.protocolClasses = [PrincipalCacheURLProtocol.self]
        sessionConfiguration.requestCachePolicy = .useProtocolCachePolicy
        sessionConfiguration.urlCache = cache
        let session = URLSession(configuration: sessionConfiguration)
        defer {
            cache.removeAllCachedResponses()
            session.invalidateAndCancel()
            PrincipalCacheURLProtocol.reset()
        }

        let baseURL = try #require(
            URL(string: "https://signed-cache-\(UUID().uuidString).example.com/v1")
        )
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL),
            session: session
        )
        let principalA = JWTBearerInterceptor { _ in "principal-a" }
        let principalB = JWTBearerInterceptor { _ in "principal-b" }

        let first = try await client.request(
            SignerPipelineEndpoint(endpointSigners: [principalA])
        )
        let second = try await client.request(
            SignerPipelineEndpoint(endpointSigners: [principalB])
        )

        #expect(first.value == "Bearer principal-a")
        #expect(second.value == "Bearer principal-b")
        let originRequests = PrincipalCacheURLProtocol.capturedRequests
        #expect(originRequests.count == 2)
        #expect(
            originRequests.map { $0.value(forHTTPHeaderField: "Authorization") }
                == ["Bearer principal-a", "Bearer principal-b"]
        )
    }
}
