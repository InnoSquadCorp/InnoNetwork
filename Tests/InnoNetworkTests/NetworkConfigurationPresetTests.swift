import Foundation
import Testing

@testable import InnoNetwork

@Suite("Network configuration presets")
struct NetworkConfigurationPresetTests {
    @Test("Package initializer caps responses at 5 MiB unless explicitly overridden")
    func packageInitializerCapsResponsesAtFiveMiB() {
        let baseURL = URL(string: "https://api.example.com")!
        let bounded = NetworkConfiguration(baseURL: baseURL)
        let explicitlyUnbounded = NetworkConfiguration(
            baseURL: baseURL,
            responseBodyBufferingPolicy: .streaming(maxBytes: nil)
        )

        #expect(
            bounded.responseBodyBufferingPolicy
                == .streaming(maxBytes: Int64(5 * 1024 * 1024))
        )
        #expect(explicitlyUnbounded.responseBodyBufferingPolicy == .streaming(maxBytes: nil))
    }

    @Test("Advanced with no packs is identical to safe defaults")
    func advancedWithoutPacksMatchesSafeDefaults() {
        let baseURL = URL(string: "https://api.example.com")!
        let safe = NetworkConfiguration.safeDefaults(baseURL: baseURL)
        let advanced = NetworkConfiguration.advanced(baseURL: baseURL)

        #expect(advanced.timeout == safe.timeout)
        #expect(advanced.timeout == 30)
        #expect(advanced.cachePolicy == safe.cachePolicy)
        #expect(advanced.cachePolicy == .useProtocolCachePolicy)
        #expect(
            advanced.eventDeliveryPolicy.maxBufferedEventsPerPartition
                == safe.eventDeliveryPolicy.maxBufferedEventsPerPartition
        )
        #expect(
            advanced.eventDeliveryPolicy.maxBufferedEventsPerConsumer
                == safe.eventDeliveryPolicy.maxBufferedEventsPerConsumer
        )
        #expect(advanced.requestPriority == safe.requestPriority)
        #expect(advanced.acceptableStatusCodes == safe.acceptableStatusCodes)
        #expect(advanced.responseCachePolicy == safe.responseCachePolicy)
    }

    @Test("Adding an unrelated pack does not change transport defaults")
    func unrelatedPackKeepsTransportDefaults() {
        let baseURL = URL(string: "https://api.example.com")!
        let configuration = NetworkConfiguration.advanced(
            baseURL: baseURL,
            resilience: ResiliencePack(retry: ExponentialBackoffRetryPolicy())
        )

        #expect(configuration.timeout == 30)
        #expect(configuration.cachePolicy == .useProtocolCachePolicy)
    }

    @Test("An enabled response cache bypasses the URLSession cache unless transport says otherwise")
    func responseCacheSelectsReloadPolicyByDefault() {
        let baseURL = URL(string: "https://api.example.com")!
        let cached = NetworkConfiguration.advanced(
            baseURL: baseURL,
            cache: CachePack(responseCachePolicy: .cacheFirst(maxAge: .seconds(60)))
        )
        let networkOnly = NetworkConfiguration.advanced(
            baseURL: baseURL,
            cache: CachePack(responseCachePolicy: .networkOnly)
        )
        let explicit = NetworkConfiguration.advanced(
            baseURL: baseURL,
            cache: CachePack(responseCachePolicy: .cacheFirst(maxAge: .seconds(60))),
            transport: TransportPack(cachePolicy: .returnCacheDataElseLoad)
        )
        let disabled = NetworkConfiguration.advanced(
            baseURL: baseURL,
            cache: CachePack(responseCachePolicy: .disabled)
        )

        #expect(cached.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(networkOnly.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(explicit.cachePolicy == .returnCacheDataElseLoad)
        #expect(disabled.cachePolicy == .useProtocolCachePolicy)
    }

    @Test("A session refresh policy bypasses the URLSession cache unless transport says otherwise")
    func sessionAuthenticationSelectsReloadPolicyByDefault() {
        let baseURL = URL(string: "https://api.example.com")!
        let refresh = RefreshTokenPolicy(currentToken: { "token" }, refreshToken: { "token" })
        let authenticated = NetworkConfiguration.advanced(
            baseURL: baseURL,
            auth: AuthPack(refreshToken: refresh)
        )
        let explicit = NetworkConfiguration.advanced(
            baseURL: baseURL,
            auth: AuthPack(refreshToken: refresh),
            transport: TransportPack(cachePolicy: .useProtocolCachePolicy)
        )

        // URLSession keys its cache by URL, not by credential, so a response
        // fetched with one session's token must not be reused after the
        // session changes.
        #expect(authenticated.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(explicit.cachePolicy == .useProtocolCachePolicy)
    }

    @Test("A request that carries a credential header never uses URLSession's cache")
    func credentialedRequestsBypassURLCache() async throws {
        let session = ContextRecordingSession()
        let configuration = NetworkConfiguration.advanced(
            baseURL: URL(string: "https://api.example.com")!,
            // The recording session answers buffered requests only.
            resilience: ResiliencePack(bodyBuffering: .buffered(maxBytes: nil)),
            auth: AuthPack(additionalRequestInterceptors: [HeaderAddingInterceptor()])
        )
        // The configuration alone cannot tell that an interceptor attaches
        // a credential, so the preset keeps the protocol cache policy.
        #expect(configuration.cachePolicy == .useProtocolCachePolicy)
        let client = DefaultNetworkClient(configuration: configuration, session: session)

        _ = try await client.request(HeaderProbe(header: "Authorization"))
        _ = try await client.request(HeaderProbe(header: "X-Tenant-Secret"))
        _ = try await client.request(HeaderProbe(header: nil))
        _ = try await client.request(HeaderProbe(header: "Authorization", offlineFirst: true))

        let requests = await session.requests
        let contexts = await session.contexts
        try #require(requests.count == 4 && contexts.count == 4)
        // A credential header: neither read from nor stored in URLCache.
        #expect(requests[0].cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(contexts[0].allowsURLCacheStorage == false)
        // A custom header is not a credential unless the configuration says so.
        #expect(requests[1].cachePolicy == .useProtocolCachePolicy)
        #expect(contexts[1].allowsURLCacheStorage)
        // No credential: the protocol cache policy applies unchanged.
        #expect(requests[2].cachePolicy == .useProtocolCachePolicy)
        #expect(contexts[2].allowsURLCacheStorage)
        // An explicitly cache-first policy is the caller's decision.
        #expect(requests[3].cachePolicy == .returnCacheDataElseLoad)
        #expect(contexts[3].allowsURLCacheStorage)
    }

    @Test("A credentialed request under a reload policy is still kept out of URLCache storage")
    func credentialedReloadRequestsAreNotStored() async throws {
        let session = ContextRecordingSession()
        let refresh = RefreshTokenPolicy(currentToken: { "token" }, refreshToken: { "token" })
        let configuration = NetworkConfiguration.advanced(
            baseURL: URL(string: "https://api.example.com")!,
            resilience: ResiliencePack(bodyBuffering: .buffered(maxBytes: nil)),
            auth: AuthPack(refreshToken: refresh)
        )
        // A refresh policy already selects the reload policy for every request.
        #expect(configuration.cachePolicy == .reloadIgnoringLocalCacheData)
        let client = DefaultNetworkClient(configuration: configuration, session: session)

        _ = try await client.request(AuthenticatedProbe())

        let requests = await session.requests
        let contexts = await session.contexts
        try #require(requests.count == 1 && contexts.count == 1)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(requests[0].cachePolicy == .reloadIgnoringLocalCacheData)
        // Reloading skips cached data on load but would still store the
        // response for the next reader of the shared cache.
        #expect(contexts[0].allowsURLCacheStorage == false)
    }

    @Test("Headers listed as sensitive count as credentials for URLCache isolation")
    func configuredSensitiveHeadersBypassURLCache() async throws {
        let session = ContextRecordingSession()
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "https://api.example.com")!,
                requestInterceptors: [HeaderAddingInterceptor()],
                responseCacheSensitiveHeaderNames: ["X-Tenant-Secret"],
                responseBodyBufferingPolicy: .buffered(maxBytes: nil)
            ),
            session: session
        )

        _ = try await client.request(HeaderProbe(header: "X-Tenant-Secret"))

        let requests = await session.requests
        let contexts = await session.contexts
        try #require(requests.count == 1 && contexts.count == 1)
        #expect(requests[0].cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(contexts[0].allowsURLCacheStorage == false)
    }

    @Test("Safe and advanced presets cap inline responses at 5 MiB")
    func presetsCapInlineResponsesAtFiveMiB() {
        let baseURL = URL(string: "https://api.example.com")!
        let safe = NetworkConfiguration.safeDefaults(baseURL: baseURL)
        let advanced = NetworkConfiguration.advanced(baseURL: baseURL)
        let expectedPolicy = ResponseBodyBufferingPolicy.streaming(
            maxBytes: Int64(5 * 1024 * 1024)
        )

        #expect(safe.responseBodyBufferingPolicy == expectedPolicy)
        #expect(advanced.responseBodyBufferingPolicy == expectedPolicy)
    }

    @Test("Advanced configuration preserves explicit unbounded buffering opt-outs")
    func advancedPreservesExplicitUnboundedBuffering() {
        let baseURL = URL(string: "https://api.example.com")!
        let streaming = NetworkConfiguration.advanced(
            baseURL: baseURL,
            resilience: ResiliencePack(bodyBuffering: .streaming(maxBytes: nil))
        )
        let buffered = NetworkConfiguration.advanced(
            baseURL: baseURL,
            resilience: ResiliencePack(bodyBuffering: .buffered(maxBytes: nil))
        )

        #expect(streaming.responseBodyBufferingPolicy == .streaming(maxBytes: nil))
        #expect(buffered.responseBodyBufferingPolicy == .buffered(maxBytes: nil))
    }

    // MARK: - Configuration packs

    @Test("ResiliencePack composes retry, circuit breaker, and coalescing policies")
    func resiliencePackComposesPolicies() {
        let baseURL = URL(string: "https://api.example.com")!
        let policy = ExponentialBackoffRetryPolicy(maxRetries: 7)
        let configuration = NetworkConfiguration.advanced(
            baseURL: baseURL,
            resilience: ResiliencePack(
                retry: policy,
                coalescing: .getOnly,
                circuitBreaker: CircuitBreakerPolicy(failureThreshold: 3)
            )
        )

        #expect(configuration.retryPolicy != nil)
        #expect(configuration.circuitBreakerPolicy != nil)
        #expect(configuration.requestCoalescingPolicy == .getOnly)
        #expect(configuration.baseURL == baseURL)
        #expect(configuration.refreshTokenPolicy == nil)
    }

    @Test("CachePack supplies the response cache")
    func cachePackSuppliesResponseCache() {
        let baseURL = URL(string: "https://api.example.com")!
        let cache = InMemoryResponseCache()
        let configuration = NetworkConfiguration.advanced(
            baseURL: baseURL,
            cache: CachePack(responseCache: cache)
        )

        #expect(configuration.responseCache != nil)
        #expect(configuration.baseURL == baseURL)
        #expect(configuration.retryPolicy == nil)
        #expect(configuration.circuitBreakerPolicy == nil)
    }

    @Test("CachePack scopes sensitive header names to one configuration")
    func cachePackScopesSensitiveHeaderNames() {
        let baseURL = URL(string: "https://api.example.com")!
        let protected = NetworkConfiguration.advanced(
            baseURL: baseURL,
            cache: CachePack(sensitiveHeaderNames: ["X-Tenant-Token"])
        )
        let defaults = NetworkConfiguration.advanced(baseURL: baseURL)

        #expect(protected.responseCacheSensitiveHeaderNames == ["x-tenant-token"])
        #expect(defaults.responseCacheSensitiveHeaderNames.isEmpty)
    }

    @Test("AuthPack supplies the refresh token policy")
    func authPackSuppliesRefreshTokenPolicy() {
        let baseURL = URL(string: "https://api.example.com")!
        let refresh = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: { "new" }
        )
        let configuration = NetworkConfiguration.advanced(
            baseURL: baseURL,
            auth: AuthPack(refreshToken: refresh)
        )

        #expect(configuration.refreshTokenPolicy != nil)
        #expect(configuration.baseURL == baseURL)
        #expect(configuration.retryPolicy == nil)
        #expect(configuration.circuitBreakerPolicy == nil)
    }

    @Test("ResiliencePack supplies the custom execution policy chain")
    func resiliencePackSuppliesCustomExecutionPolicies() {
        let baseURL = URL(string: "https://api.example.com")!
        let configuration = NetworkConfiguration.advanced(
            baseURL: baseURL,
            resilience: ResiliencePack(
                customExecutionPolicies: [PassthroughExecutionPolicy()]
            )
        )

        #expect(configuration.customExecutionPolicies.count == 1)
        #expect(configuration.baseURL == baseURL)
        #expect(configuration.retryPolicy == nil)
        #expect(configuration.circuitBreakerPolicy == nil)
    }

    @Test("ObservabilityPack supplies network event observers")
    func observabilityPackSuppliesEventObservers() {
        let baseURL = URL(string: "https://api.example.com")!
        let configuration = NetworkConfiguration.advanced(
            baseURL: baseURL,
            observability: ObservabilityPack(
                eventObservers: [TestNetworkEventObserver()]
            )
        )

        #expect(configuration.eventObservers.count == 1)
        #expect(configuration.baseURL == baseURL)
        #expect(configuration.retryPolicy == nil)
        #expect(configuration.circuitBreakerPolicy == nil)
    }
}

/// Records every request and the per-task context it was sent with.
private actor ContextRecordingSession: URLSessionProtocol {
    var requests: [URLRequest] = []
    var contexts: [NetworkRequestContext] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return (
            Data(),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: ["Cache-Control": "max-age=60"]
            )!
        )
    }

    func data(for request: URLRequest, context: NetworkRequestContext) async throws -> (Data, URLResponse) {
        contexts.append(context)
        return try await data(for: request)
    }
}

/// Attaches the header named by the probe, the way an application
/// interceptor attaches a credential, and optionally chooses an offline-first
/// cache policy for the request.
private struct HeaderAddingInterceptor: RequestInterceptor {
    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        if let name = request.value(forHTTPHeaderField: HeaderProbe.credentialHeaderInstruction) {
            request.setValue(nil, forHTTPHeaderField: HeaderProbe.credentialHeaderInstruction)
            request.setValue("credential-value", forHTTPHeaderField: name)
        }
        if request.value(forHTTPHeaderField: HeaderProbe.offlineFirstInstruction) != nil {
            request.setValue(nil, forHTTPHeaderField: HeaderProbe.offlineFirstInstruction)
            request.cachePolicy = .returnCacheDataElseLoad
        }
        return request
    }
}

private struct AuthenticatedProbe: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = EmptyResponse

    var sessionAuthentication: SessionAuthentication { .required }
    var method: HTTPMethod { .get }
    var path: String { "/me" }
}

private struct HeaderProbe: APIDefinition {
    static let credentialHeaderInstruction = "X-Probe-Credential-Header"
    static let offlineFirstInstruction = "X-Probe-Offline-First"

    typealias Parameter = EmptyParameter
    typealias APIResponse = EmptyResponse

    let header: String?
    var offlineFirst = false

    var sessionAuthentication: SessionAuthentication { .anonymous }
    var method: HTTPMethod { .get }
    var path: String { "/probe" }
    var headers: HTTPHeaders {
        var headers = HTTPHeaders()
        if let header {
            headers.add(name: Self.credentialHeaderInstruction, value: header)
        }
        if offlineFirst {
            headers.add(name: Self.offlineFirstInstruction, value: "1")
        }
        return headers
    }
}

private struct TestNetworkEventObserver: NetworkEventObserving {
    func handle(_ event: NetworkEvent) async {
        _ = event
    }
}

private struct PassthroughExecutionPolicy: RequestExecutionPolicy {
    func execute(
        input: RequestExecutionInput,
        context: RequestExecutionContext,
        next: RequestExecutionNext
    ) async throws -> Response {
        _ = context
        _ = input
        return try await next.execute()
    }
}
