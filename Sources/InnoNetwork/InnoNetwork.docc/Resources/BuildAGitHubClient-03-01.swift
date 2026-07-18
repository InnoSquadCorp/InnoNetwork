import Foundation
import InnoNetwork

struct User: Decodable, Sendable {
    let login: String
    let id: Int
    let name: String?
}

@APIDefinition(method: .get, path: "/users/{login}", auth: .anonymous)
struct GetUser {
    typealias APIResponse = User

    let login: String
}

func makeClient() -> DefaultNetworkClient? {
    guard let baseURL = URL(string: "https://api.github.com") else {
        return nil
    }
    return DefaultNetworkClient(baseURL: baseURL)
}
