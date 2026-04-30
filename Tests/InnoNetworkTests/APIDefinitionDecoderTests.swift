import Foundation
import Testing

@testable import InnoNetwork

private struct ExplicitDecoderRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = String

    var method: HTTPMethod { .get }
    var path: String { "/decoder-explicit" }

    var transport: TransportPolicy<String> {
        .custom(encoding: .query(URLQueryEncoder(), rootKey: nil)) { _, _ in
            "decoded-by-explicit-strategy"
        }
    }
}


@Suite("Decoder Factory Tests")
struct APIDefinitionDecoderTests {
    @Test("Request execution uses explicit transport responseDecoder")
    func explicitResponseDecoderIsUsed() async throws {
        let configuration = makeTestNetworkConfiguration(baseURL: "https://example.com")
        let session = MockURLSession()
        session.setMockResponse(statusCode: 200, data: Data("ignored".utf8))
        let client = DefaultNetworkClient(configuration: configuration, session: session)

        let result = try await client.request(ExplicitDecoderRequest())
        #expect(result == "decoded-by-explicit-strategy")
    }

    @Test("Transport policy preserves explicit responseDecoder override")
    func transportPolicyUsesExplicitDecoderOverride() throws {
        let request = ExplicitDecoderRequest()
        let httpResponse = try #require(
            HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )
        let response = Response(statusCode: 200, data: Data(), response: httpResponse)

        let result = try request.transport.responseDecoder.decode(data: Data(), response: response)
        #expect(result == "decoded-by-explicit-strategy")
    }
}
