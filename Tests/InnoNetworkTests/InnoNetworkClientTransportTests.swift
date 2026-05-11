import Foundation
import HTTPTypes
import InnoNetworkOpenAPI
import OpenAPIRuntime
import Testing

@testable import InnoNetwork

@Suite("InnoNetworkClientTransport")
struct InnoNetworkClientTransportTests {
    @Test("Constructs with default byte limits")
    func constructsWithDefaultByteLimits() {
        let transport = InnoNetworkClientTransport(session: URLSession(configuration: .ephemeral))

        #expect(transport.requestBodyByteLimit == 50 * 1024 * 1024)
        #expect(transport.responseBodyByteLimit == 50 * 1024 * 1024)
    }

    @Test("Custom byte limits are preserved")
    func customByteLimitsArePreserved() {
        let transport = InnoNetworkClientTransport(
            session: URLSession(configuration: .ephemeral),
            requestBodyByteLimit: 1024,
            responseBodyByteLimit: 2048
        )

        #expect(transport.requestBodyByteLimit == 1024)
        #expect(transport.responseBodyByteLimit == 2048)
    }

    @Test("Surfaces a typed error for an unresolvable request URL")
    func surfacesTypedErrorForUnresolvableURL() async throws {
        let transport = InnoNetworkClientTransport(session: URLSession(configuration: .ephemeral))
        let request = HTTPRequest(method: .get, scheme: nil, authority: nil, path: nil)

        do {
            _ = try await transport.send(
                request,
                body: nil,
                baseURL: URL(string: "https://api.example.com")!,
                operationID: "test"
            )
            Issue.record("expected InnoNetworkClientTransportError.invalidRequestURL")
        } catch let error as InnoNetworkClientTransportError {
            guard case .invalidRequestURL = error else {
                Issue.record("expected .invalidRequestURL, got \(error)")
                return
            }
        }
    }
}
