import Foundation
import InnoNetwork
import InnoNetworkCodegen

struct User: Decodable, Sendable {
    let id: Int
    let name: String
}

@APIDefinition(method: .get, path: "/users/{id}")
struct GetUser {
    let id: Int
    typealias APIResponse = User
}

let typed = GetUser(id: 1)
let builder = #endpoint(.get, "/users/1", as: User.self)

print(typed.path)
print(builder.path)
