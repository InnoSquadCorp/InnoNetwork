# Migration From Alamofire

Use this cookbook when an app has a small Alamofire layer and wants to move the
first endpoint to InnoNetwork without adopting macros, streaming, or custom
transport hooks. For deeper behaviour mapping, see
[`docs/MigrationGuides.md`](MigrationGuides.md) and the DocC
`MigrationFromAlamofire` article.

## Before: Alamofire request

```swift
import Alamofire

struct User: Decodable {
    let id: Int
    let name: String
}

struct CreatePost: Encodable {
    let title: String
    let body: String
}

final class API {
    private let baseURL = URL(string: "https://api.example.com/v1")!

    func user(id: Int) async throws -> User {
        try await AF.request(baseURL.appending(path: "users/\(id)"))
            .validate(statusCode: 200..<300)
            .serializingDecodable(User.self)
            .value
    }

    func createPost(_ post: CreatePost, token: String) async throws {
        try await AF.request(
            baseURL.appending(path: "posts"),
            method: .post,
            parameters: post,
            encoder: JSONParameterEncoder.default,
            headers: ["Authorization": "Bearer \(token)"]
        )
        .validate(statusCode: 200..<300)
        .serializingData()
        .value
    }
}
```

## After: EndpointBuilder first path

```swift
import InnoNetwork

let client = DefaultNetworkClient(
    configuration: .recommendedForProduction(
        baseURL: URL(string: "https://api.example.com/v1")!
    )
)

let user = try await client.request(
    EndpointBuilder<EmptyResponse, PublicAuthScope>
        .get("/users/\(id)")
        .decoding(User.self)
)

let token = currentAccessToken
let _: EmptyResponse = try await client.request(
    EndpointBuilder<EmptyResponse, PublicAuthScope>
        .post("/posts")
        .body(CreatePost(title: "Hello", body: "World"))
        .header("Authorization", value: "Bearer \(token)")
        .header("Idempotency-Key", value: UUID().uuidString)
)
```

Start with `EndpointBuilder`, move auth refresh into `RefreshTokenPolicy`, and
only introduce `APIDefinition` when the endpoint itself needs custom transport,
per-endpoint interceptors, multipart, or streaming.
