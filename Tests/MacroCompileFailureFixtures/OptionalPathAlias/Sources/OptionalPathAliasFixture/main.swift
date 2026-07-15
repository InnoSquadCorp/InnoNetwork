import InnoNetwork

private typealias OptionalUserID = Int?

private struct User: Decodable, Sendable {
    let id: Int
}

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
private struct GetUser {
    typealias APIResponse = User

    let id: OptionalUserID
}

_ = GetUser(id: nil)
