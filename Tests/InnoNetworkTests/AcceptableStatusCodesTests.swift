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
}
