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
        var sessionAuthentication: SessionAuthentication { .anonymous }
        var headers: HTTPHeaders {
            HTTPHeaders(["X-Client": "openapi"])
        }
    }

    private struct HeadUserOperation: OpenAPIRestOperation {
        typealias Response = User

        var method: HTTPMethod { .head }
        var path: String { "/users/1" }
        var sessionAuthentication: SessionAuthentication { .anonymous }
    }

    @Test("OpenAPIRequest forwards operation shape")
    func openAPIRequestForwardsOperationShape() async {
        let request = OpenAPIRequest(GetUserOperation())

        #expect(request.method == .get)
        #expect(request.path == "/users/1")
        #expect(request.headers.value(for: "X-Client") == "openapi")
        #expect(request.parameters == nil)
    }

    @Test("OpenAPI HEAD operations default to query-string transport")
    func openAPIHeadOperationUsesQueryTransport() {
        let request = OpenAPIRequest(HeadUserOperation())

        if case .query = request.transport.requestEncoding {
            // expected
        } else {
            Issue.record("Default OpenAPI HEAD transport should be .query")
        }
    }
}
