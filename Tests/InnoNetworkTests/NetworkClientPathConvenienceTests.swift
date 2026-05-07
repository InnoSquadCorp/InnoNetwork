import Foundation
import Testing

@testable import InnoNetwork

private struct PathConvenienceUser: Codable, Sendable, Equatable {
    let id: Int
    let name: String
}

@Suite
struct NetworkClientPathConvenienceTests {
    @Test
    func pathOverloadDecodesResponseFromCallSiteAnnotation() async throws {
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(PathConvenienceUser(id: 7, name: "Ethan"))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        let user: PathConvenienceUser = try await client.request("/users/7")

        #expect(user == PathConvenienceUser(id: 7, name: "Ethan"))
    }

    @Test
    func pathOverloadDispatchesNonGetMethod() async throws {
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(PathConvenienceUser(id: 8, name: "Created"))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        let user: PathConvenienceUser = try await client.request(
            "/users",
            method: .post
        )

        #expect(user == PathConvenienceUser(id: 8, name: "Created"))
        #expect(mockSession.capturedRequest?.httpMethod == "POST")
    }
}
