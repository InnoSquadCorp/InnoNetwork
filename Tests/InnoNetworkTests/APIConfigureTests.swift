import Foundation
import Testing
@testable import InnoNetwork


struct CustomBaseURLAPI: APIConfigure {
    var host: String { "api.example.com" }
    var basePath: String { "v1" }
    var baseURL: URL? { URL(string: "https://api.example.com/v1") }
}


struct BaseURLDispatchRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = BaseURLResponse

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
}


struct BaseURLResponse: Codable, Sendable, Equatable {
    let id: Int
    let name: String
}


@Suite("API Configure Dispatch Tests")
struct APIConfigureDispatchTests {
    @Test("Custom baseURL override is used via existential dispatch")
    func customBaseURLDispatchesCorrectly() async throws {
        let mockSession = MockURLSession()
        let expectedResponse = BaseURLResponse(id: 1, name: "Tester")
        try mockSession.setMockJSON(expectedResponse)

        let client = try DefaultNetworkClient(
            configuration: CustomBaseURLAPI(),
            session: mockSession
        )

        let response = try await client.request(BaseURLDispatchRequest())
        #expect(response == expectedResponse)
        #expect(mockSession.capturedRequest?.url?.absoluteString.hasPrefix("https://api.example.com/v1/users/1") == true)
    }
}
