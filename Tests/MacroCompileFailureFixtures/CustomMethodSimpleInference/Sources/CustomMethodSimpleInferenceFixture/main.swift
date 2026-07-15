import InnoNetwork

private struct Resource: Decodable, Sendable {}

private struct SearchQuery: Encodable, Sendable {
    let depth: Int
}

@APIDefinition(
    method: HTTPMethod(rawValue: "PROPFIND")!,
    path: "/resources",
    auth: .anonymous
)
private struct FindResources {
    typealias APIResponse = [Resource]

    let query: SearchQuery
}

_ = FindResources(query: SearchQuery(depth: 1))
