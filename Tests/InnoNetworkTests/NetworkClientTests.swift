import Foundation
import Testing
@testable import InnoNetwork


struct GetProfile: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Profile

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
}


struct Profile: Decodable, Sendable {
    let id: Int
    let name: String
}


@Suite
struct NetworkClientTests {
    let client = try! DefaultNetworkClient(configuration: APIDefinitionTests())

    private var runIntegrationTests: Bool {
        ProcessInfo.processInfo.environment["INNONETWORK_RUN_INTEGRATION_TESTS"] == "1"
    }

    @Test func getRequestSuccess() async throws {
        guard runIntegrationTests else { return }
        let profile = try await client.request(GetProfile())
        #expect(profile.id == 1)
        #expect(profile.name == "Leanne Graham")
    }
}


struct APIDefinitionTests: APIConfigure {
    var host: String { "https://jsonplaceholder.typicode.com" }
    var basePath: String { "" }
}
