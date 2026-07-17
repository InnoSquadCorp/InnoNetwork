import InnoNetwork

private struct User: Decodable, Sendable {
    let id: Int
}

private struct GetUser {
    typealias APIResponse = User
    let id: Int
}

private func loadUser(
    client: any NetworkClient
) async throws -> User {
    try await client.request(GetUser(id: 42))
}

private func loadTaggedUser(
    client: any NetworkClient
) async throws -> User {
    try await client.request(GetUser(id: 42), tag: CancellationTag("profile"))
}

_ = loadUser
_ = loadTaggedUser
