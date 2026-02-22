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
}
