import Foundation
import Testing

@testable import InnoNetwork

@Suite("Request Execution Policy Tests")
struct RequestExecutionPolicyTests {
    private struct DataEcho: APIDefinition {
        typealias Parameter = EmptyParameter
        typealias APIResponse = Data

        var method: HTTPMethod { .get }
        var path: String { "/policy" }
        var transport: TransportPolicy<Data> {
            .custom(encoding: .json(defaultRequestEncoder)) { data, _ in data }
        }
    }

    private struct HeaderPolicy: RequestExecutionPolicy {
        func execute(
            input: RequestExecutionInput,
            context: RequestExecutionContext,
            next: RequestExecutionNext
        ) async throws -> Response {
            var request = input.request
            request.setValue("policy-\(context.retryIndex)", forHTTPHeaderField: "X-Policy")
            return try await next.execute(request)
        }
    }

    private struct BodyRewritePolicy: RequestExecutionPolicy {
        let body: Data

        func execute(
            input: RequestExecutionInput,
            context: RequestExecutionContext,
            next: RequestExecutionNext
        ) async throws -> Response {
            let response = try await next.execute(input.request)
            guard let httpResponse = response.response else { return response }
            return Response(
                statusCode: response.statusCode,
                data: body,
                request: response.request,
                response: httpResponse
            )
        }
    }

    @Test("Custom execution policy can adapt the transport request")
    func customPolicyAdaptsTransportRequest() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data("ok".utf8))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                customExecutionPolicies: [HeaderPolicy()]
            ),
            session: mockSession
        )

        _ = try await client.request(DataEcho())

        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "X-Policy") == "policy-0")
    }

    @Test("Custom execution policy can rewrite the transport response before decode")
    func customPolicyRewritesResponseBeforeDecode() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data("original".utf8))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                customExecutionPolicies: [BodyRewritePolicy(body: Data("rewritten".utf8))]
            ),
            session: mockSession
        )

        let data = try await client.request(DataEcho())

        #expect(String(data: data, encoding: .utf8) == "rewritten")
    }
}
