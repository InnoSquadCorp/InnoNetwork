import InnoNetwork

private enum PolicyAlias {
    static let anonymous: SessionAuthentication = .required
}

private struct User: Decodable, Sendable {}

@APIDefinition(method: .get, path: "/users", auth: PolicyAlias.anonymous)
private struct ListUsers {
    typealias APIResponse = [User]
}

_ = ListUsers()
