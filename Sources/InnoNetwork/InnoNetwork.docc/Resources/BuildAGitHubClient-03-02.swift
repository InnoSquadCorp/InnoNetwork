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
    var path: String {
        "/users/\(EndpointPathEncoding.percentEncodedSegment(login))"
    }
}

func makeClient() -> DefaultNetworkClient? {
    guard let baseURL = URL(string: "https://api.github.com") else {
        return nil
    }
    return DefaultNetworkClient(
        configuration: .safeDefaults(baseURL: baseURL)
    )
}

func fetchInnoSquad() async {
    guard let client = makeClient() else { return }
    do {
        let user = try await client.request(GetUser(login: "InnoSquadCorp"))
        print("\(user.login) - id: \(user.id)")
    } catch let error as NetworkError {
        print("Failed: \(error.localizedDescription)")
    } catch {
        print("Unexpected: \(error)")
    }
}
