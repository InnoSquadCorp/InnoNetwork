import Foundation
import InnoNetwork

struct User: Decodable, Sendable {
    let login: String
    let id: Int
    let name: String?
}

struct GetUser: APIDefinition {
    typealias APIResponse = User

    let login: String

    var method: HTTPMethod { .get }
    var path: String { "/users/\(login)" }
}

func makeClient() -> DefaultNetworkClient? {
    guard let baseURL = URL(string: "https://api.github.com") else {
        return nil
    }
    return DefaultNetworkClient(
        configuration: .safeDefaults(baseURL: baseURL)
    )
}
