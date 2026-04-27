import Foundation
import Testing
@testable import InnoNetwork


@Suite("Acceptable Status Codes Tests")
struct AcceptableStatusCodesTests {

    private struct EmptyEcho: APIDefinition, HTTPEmptyResponseDecodable {
        typealias Parameter = EmptyParameter
        typealias APIResponse = EmptyEcho
        var method: HTTPMethod { .get }
        var path: String { "/" }

        static func emptyResponseValue() -> EmptyEcho { EmptyEcho() }
    }

    @Test("Default acceptable status codes still cover 200..<300")
    func defaultRangeAccepts2xx() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 204)

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        // 204 is inside the default 200..<300 set so the request must
        // succeed without throwing.
        _ = try await client.request(EmptyEcho())
    }

    @Test("Default acceptable status codes still reject 4xx")
    func defaultRangeRejects4xx() async {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 404)

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        await #expect(throws: NetworkError.self) {
            _ = try await client.request(EmptyEcho())
        }
    }

    @Test("Custom acceptable set including 304 routes Not-Modified through to consumer")
    func customSetIncludes304() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 304)

        let configuration = makeTestNetworkConfiguration(
            baseURL: "https://api.example.com/v1",
            acceptableStatusCodes: NetworkConfiguration.defaultAcceptableStatusCodes.union([304])
        )
        let client = DefaultNetworkClient(
            configuration: configuration,
            session: mockSession
        )

        // 304 normally throws because it lives outside 200..<300, but the
        // custom set should allow it to flow through as a successful empty
        // response.
        _ = try await client.request(EmptyEcho())
    }

    @Test("Custom acceptable set excluding 200 makes 200 throw")
    func customSetCanShrink() async {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200)

        // Synthetic narrow set: only 201 is acceptable.
        let configuration = makeTestNetworkConfiguration(
            baseURL: "https://api.example.com/v1",
            acceptableStatusCodes: [201]
        )
        let client = DefaultNetworkClient(
            configuration: configuration,
            session: mockSession
        )

        await #expect(throws: NetworkError.self) {
            _ = try await client.request(EmptyEcho())
        }
    }

    @Test("AdvancedBuilder exposes acceptableStatusCodes for tuning")
    func advancedBuilderExposesProperty() {
        let configuration = NetworkConfiguration.advanced(
            baseURL: URL(string: "https://api.example.com/v1")!
        ) { builder in
            builder.acceptableStatusCodes = [200, 201, 304]
        }
        #expect(configuration.acceptableStatusCodes == [200, 201, 304])
    }

    // MARK: - Per-endpoint override

    private struct EndpointAccepts304: APIDefinition, HTTPEmptyResponseDecodable {
        typealias Parameter = EmptyParameter
        typealias APIResponse = EndpointAccepts304
        var method: HTTPMethod { .get }
        var path: String { "/cached" }

        // Accept the full default range plus 304. 304 is normally rejected by
        // the session-wide configuration; this override flips it just for
        // this endpoint.
        var acceptableStatusCodes: Set<Int>? {
            NetworkConfiguration.defaultAcceptableStatusCodes.union([304])
        }

        static func emptyResponseValue() -> EndpointAccepts304 { EndpointAccepts304() }
    }

    private struct EndpointRejectsEverythingButCreated: APIDefinition, HTTPEmptyResponseDecodable {
        typealias Parameter = EmptyParameter
        typealias APIResponse = EndpointRejectsEverythingButCreated
        var method: HTTPMethod { .post }
        var path: String { "/strict" }

        var acceptableStatusCodes: Set<Int>? { [201] }

        static func emptyResponseValue() -> EndpointRejectsEverythingButCreated { EndpointRejectsEverythingButCreated() }
    }

    @Test("Per-endpoint override broadens acceptable codes without touching session defaults")
    func endpointOverrideBroadens() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 304)

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        // The session's configuration still uses 200..<300, but the endpoint
        // says "304 is fine for me", so the request must succeed.
        _ = try await client.request(EndpointAccepts304())
    }

    @Test("Per-endpoint override narrows acceptable codes below the session default")
    func endpointOverrideNarrows() async {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200)

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        // Session default would accept 200, but the endpoint says only 201
        // counts as success. The request must throw NetworkError.statusCode.
        await #expect(throws: NetworkError.self) {
            _ = try await client.request(EndpointRejectsEverythingButCreated())
        }
    }

    @Test("Endpoint override does not leak across requests")
    func endpointOverrideIsScoped() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 304)

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        // The override-aware endpoint accepts 304.
        _ = try await client.request(EndpointAccepts304())

        // A different endpoint without an override on the same client must
        // still reject 304 because session-wide acceptable codes apply.
        await #expect(throws: NetworkError.self) {
            _ = try await client.request(EmptyEcho())
        }
    }
}
