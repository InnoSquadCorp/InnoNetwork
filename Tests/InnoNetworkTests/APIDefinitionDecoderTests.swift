import Foundation
import Testing
@testable import InnoNetwork


private struct DecoderTestRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = EmptyResponse

    var method: HTTPMethod { .get }
    var path: String { "/decoder" }
}

private struct DecoderTestMultipartRequest: MultipartAPIDefinition {
    typealias APIResponse = EmptyResponse

    var multipartFormData: MultipartFormData {
        var formData = MultipartFormData()
        formData.append("value", name: "name")
        return formData
    }

    var method: HTTPMethod { .post }
    var path: String { "/decoder-multipart" }
}

private struct ExplicitDecoderRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = String

    var method: HTTPMethod { .get }
    var path: String { "/decoder-explicit" }

    var responseDecoder: AnyResponseDecoder<String> {
        AnyResponseDecoder { _, _ in "decoded-by-explicit-strategy" }
    }
}


@Suite("Decoder Factory Tests")
struct APIDefinitionDecoderTests {
    @Test("APIDefinition default decoder is not shared")
    func apiDefinitionDecoderNotShared() {
        let request = DecoderTestRequest()
        let first = request.decoder
        let second = request.decoder

        #expect(first !== second)
    }

    @Test("MultipartAPIDefinition default decoder is not shared")
    func multipartDecoderNotShared() {
        let request = DecoderTestMultipartRequest()
        let first = request.decoder
        let second = request.decoder

        #expect(first !== second)
    }

    @Test("Request execution uses explicit responseDecoder")
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

        let result = try request.transportPolicy.responseDecoder.decode(data: Data(), response: response)
        #expect(result == "decoded-by-explicit-strategy")
    }
}
