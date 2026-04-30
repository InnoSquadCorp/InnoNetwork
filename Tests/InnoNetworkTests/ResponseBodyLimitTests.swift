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

        var transport: TransportPolicy<Data> {
            .custom(encoding: .json(defaultRequestEncoder)) { data, _ in data }
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
}
