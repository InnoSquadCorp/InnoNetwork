import Foundation
import InnoNetworkOpenAPI
import Testing

@testable import InnoNetwork

@Suite("OpenAPI companion adapter")
struct OpenAPICompanionTests {
    private struct User: Codable, Sendable, Equatable {
        let id: Int
    }

    private struct GetUserOperation: OpenAPIRestOperation {
        typealias Response = User

        var method: HTTPMethod { .get }
        var path: String { "/users/1" }
        var headers: HTTPHeaders {
            HTTPHeaders(["X-Client": "openapi"])
        }
    }

    @Test("OpenAPIRequest forwards operation shape")
    func openAPIRequestForwardsOperationShape() {
        let request = OpenAPIRequest(GetUserOperation())

        #expect(request.method == .get)
        #expect(request.path == "/users/1")
        #expect(request.headers.value(for: "X-Client") == "openapi")
        #expect(request.parameters == nil)
    }
}
