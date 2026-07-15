import Foundation
import InnoNetwork

struct User: Decodable, Sendable {
    let id: Int
    let name: String
}

struct ListUsersQuery: Encodable, Sendable {
    let page: Int
}

struct CreateUserRequest: Encodable, Sendable {
    let name: String
}

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
struct GetUser {
    let id: Int
    typealias APIResponse = User
}

@APIDefinition(method: .get, path: "/users", auth: .anonymous)
struct ListUsers {
    typealias APIResponse = [User]
    let query: ListUsersQuery
}

@APIDefinition(method: .post, path: "/users", auth: .required)
struct CreateUser {
    typealias APIResponse = User
    let body: CreateUserRequest
}

let typed = GetUser(id: 1)
let list = ListUsers(query: ListUsersQuery(page: 1))
let create = CreateUser(body: CreateUserRequest(name: "Blob"))

print(typed.path)
print(list.parameters?.page ?? 0)
print(create.parameters?.name ?? "")
