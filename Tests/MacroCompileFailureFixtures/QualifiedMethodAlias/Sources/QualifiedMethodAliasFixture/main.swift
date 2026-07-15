import InnoNetwork

private enum MethodAlias {
    static let get: HTTPMethod = .post
}

private struct User: Decodable, Sendable {}

private struct Query: Encodable, Sendable {
    let page: Int
}

@APIDefinition(method: MethodAlias.get, path: "/users", auth: .anonymous)
private struct ListUsers {
    typealias APIResponse = [User]

    let query: Query
}

_ = ListUsers(query: Query(page: 1))
