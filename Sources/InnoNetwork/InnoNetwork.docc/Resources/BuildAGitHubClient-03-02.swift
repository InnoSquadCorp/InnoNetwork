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

func fetchInnoSquad() async {
    guard let client = makeClient() else { return }
    do {
        let user = try await client.request(GetUser(login: "InnoSquadCorp"))
        print("\(user.login) - id: \(user.id)")
    } catch {
        print("Failed: \(error.localizedDescription)")
    }
}
