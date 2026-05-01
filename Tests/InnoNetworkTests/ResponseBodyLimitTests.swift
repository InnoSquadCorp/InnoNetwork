import Foundation
import Testing

@testable import InnoNetwork

@Suite("Response Body Limit Tests")
struct ResponseBodyLimitTests {

    private struct DataEcho: APIDefinition {
        typealias Parameter = EmptyParameter
        typealias APIResponse = Data
        var method: HTTPMethod { .get }
        var path: String { "/echo" }
        var headers: HTTPHeaders { [] }

        var transport: TransportPolicy<Data> {
            .custom(encoding: .json(defaultRequestEncoder)) { data, _ in data }
        }
    }

    private struct ReplacingResponseBody: ResponseInterceptor {
        let data: Data

        func adapt(_ urlResponse: Response, request: URLRequest) async throws -> Response {
            guard let response = urlResponse.response else { return urlResponse }
            return Response(
                statusCode: urlResponse.statusCode,
                data: data,
                request: urlResponse.request,
                response: response
            )
        }
    }

    private struct ReplacingDecodableData: DecodingInterceptor {
        let data: Data

        func willDecode(data: Data, response: Response) async throws -> Data {
            self.data
        }
    }

    @Test("Body under the limit passes through unchanged")
    func underLimitPasses() async throws {
        let payload = Data(repeating: 0xAA, count: 1_024)
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: payload)

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                responseBodyLimit: 8_192
            ),
            session: mockSession
        )

        let received = try await client.request(DataEcho())
        #expect(received.count == payload.count)
    }

    @Test("Body equal to the limit is allowed (boundary inclusive)")
    func atLimitIsAllowed() async throws {
        let payload = Data(repeating: 0xBB, count: 4_096)
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: payload)

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                responseBodyLimit: 4_096
            ),
            session: mockSession
        )

        let received = try await client.request(DataEcho())
        #expect(received.count == 4_096)
    }

    @Test("Body above the limit throws responseTooLarge with limit and observed bytes")
    func overLimitThrows() async throws {
        let payload = Data(repeating: 0xCC, count: 5 * 1_024)
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: payload)

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                responseBodyLimit: 1_024
            ),
            session: mockSession
        )

        do {
            _ = try await client.request(DataEcho())
            Issue.record("Expected NetworkError.responseTooLarge")
        } catch let error as NetworkError {
            switch error {
            case .responseTooLarge(let limit, let observed):
                #expect(limit == 1_024)
                #expect(observed == Int64(payload.count))
            default:
                Issue.record("Expected NetworkError.responseTooLarge, got \(error)")
            }
        }
    }

    @Test("Fresh cache hit above the limit throws before decode")
    func oversizedFreshCacheHitThrows() async throws {
        let payload = Data(repeating: 0xEF, count: 5 * 1_024)
        let cache = InMemoryResponseCache()
        let request = URLRequest(url: URL(string: "https://api.example.com/v1/echo")!)
        let key = try #require(ResponseCacheKey(request: request))
        await cache.set(key, CachedResponse(data: payload))

        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data("unused".utf8))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                responseCachePolicy: .cacheFirst(maxAge: .seconds(600)),
                responseCache: cache,
                responseBodyLimit: 1_024
            ),
            session: mockSession
        )

        await expectResponseTooLarge(observed: Int64(payload.count)) {
            _ = try await client.request(DataEcho())
        }
        #expect(mockSession.capturedRequest == nil)
    }

    @Test("Oversize response is not written to the response cache")
    func oversizeResponseDoesNotPoisonCache() async throws {
        let payload = Data(repeating: 0xEE, count: 5 * 1_024)
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: payload)

        let cache = InMemoryResponseCache()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                responseCachePolicy: .cacheFirst(maxAge: .seconds(600)),
                responseCache: cache,
                responseBodyLimit: 1_024
            ),
            session: mockSession
        )

        do {
            _ = try await client.request(DataEcho())
            Issue.record("Expected NetworkError.responseTooLarge")
        } catch is NetworkError {
            // Expected.
        }

        let request = URLRequest(url: URL(string: "https://api.example.com/v1/echo")!)
        if let key = ResponseCacheKey(request: request) {
            let cached = await cache.get(key)
            #expect(cached == nil, "Oversize response must not be cached")
        }
    }

    @Test("Stale background revalidation above the limit does not replace cache")
    func oversizedStaleRevalidationDoesNotReplaceCache() async throws {
        let stalePayload = Data("stale".utf8)
        let oversizedPayload = Data(repeating: 0xFA, count: 5 * 1_024)
        let cache = InMemoryResponseCache()
        let request = URLRequest(url: URL(string: "https://api.example.com/v1/echo")!)
        let key = try #require(ResponseCacheKey(request: request))
        await cache.set(
            key,
            CachedResponse(
                data: stalePayload,
                headers: ["ETag": "v1"],
                storedAt: Date(timeIntervalSinceNow: -5)
            )
        )

        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: oversizedPayload)
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                responseCachePolicy: .staleWhileRevalidate(maxAge: .seconds(1), staleWindow: .seconds(10)),
                responseCache: cache,
                responseBodyLimit: 1_024
            ),
            session: mockSession
        )

        let received = try await client.request(DataEcho())

        #expect(received == stalePayload)
        try await waitUntil {
            mockSession.capturedRequest != nil
        }
        try await Task.sleep(for: .milliseconds(50))
        let cached = try #require(await cache.get(key))
        #expect(cached.data == stalePayload)
    }

    @Test("Response interceptor expansion above the limit throws before decode")
    func responseInterceptorExpansionThrows() async throws {
        let oversizedPayload = Data(repeating: 0xAB, count: 5 * 1_024)
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data("small".utf8))

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                responseInterceptors: [ReplacingResponseBody(data: oversizedPayload)],
                responseBodyLimit: 1_024
            ),
            session: mockSession
        )

        await expectResponseTooLarge(observed: Int64(oversizedPayload.count)) {
            _ = try await client.request(DataEcho())
        }
    }

    @Test("willDecode expansion above the limit throws before decode")
    func willDecodeExpansionThrows() async throws {
        let oversizedPayload = Data(repeating: 0xCD, count: 5 * 1_024)
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data("small".utf8))

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                decodingInterceptors: [ReplacingDecodableData(data: oversizedPayload)],
                responseBodyLimit: 1_024
            ),
            session: mockSession
        )

        await expectResponseTooLarge(observed: Int64(oversizedPayload.count)) {
            _ = try await client.request(DataEcho())
        }
    }

    @Test("nil limit (default) keeps the unbounded behaviour")
    func nilLimitIsUnbounded() async throws {
        let payload = Data(repeating: 0xDD, count: 10 * 1_024 * 1_024)
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: payload)

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        let received = try await client.request(DataEcho())
        #expect(received.count == payload.count)
    }

    @Test("NSError bridge for responseTooLarge uses stable code")
    func nsErrorCodeIsStable() {
        let error = NetworkError.responseTooLarge(limit: 100, observed: 500) as NSError
        #expect(error.domain == NetworkError.errorDomain)
        #expect(error.code == 4002)
    }

    private func expectResponseTooLarge(
        limit: Int64 = 1_024,
        observed: Int64,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected NetworkError.responseTooLarge")
        } catch let error as NetworkError {
            switch error {
            case .responseTooLarge(let actualLimit, let actualObserved):
                #expect(actualLimit == limit)
                #expect(actualObserved == observed)
            default:
                Issue.record("Expected NetworkError.responseTooLarge, got \(error)")
            }
        } catch {
            Issue.record("Expected NetworkError.responseTooLarge, got \(error)")
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for asynchronous condition.")
    }
}
