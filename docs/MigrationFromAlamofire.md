# Migration From Alamofire

Use this cookbook when an app has a small Alamofire layer and wants to move the
first endpoint to explicit, macro-assisted InnoNetwork value types without
adopting streaming or custom transport hooks. For deeper behaviour mapping, see
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

## After: explicit endpoint structs

```swift
import Foundation
import InnoNetwork

@APIDefinition(method: .get, path: "/users/{id}", auth: .public)
struct GetUser {
    typealias APIResponse = User
    let id: Int
}

@APIDefinition(method: .post, path: "/posts", auth: .public)
struct CreatePostRequest {
    typealias APIResponse = EmptyResponse

    let body: CreatePost
    let token: String

    var headers: HTTPHeaders {
        ["Authorization": "Bearer \(token)",
         "Idempotency-Key": UUID().uuidString]
    }
}

let client = DefaultNetworkClient(
    configuration: .recommendedForProduction(
        baseURL: URL(string: "https://api.example.com/v1")!
    )
)

let user = try await client.request(GetUser(id: id))

let token = currentAccessToken
let _: EmptyResponse = try await client.request(
    CreatePostRequest(
        body: CreatePost(title: "Hello", body: "World"),
        token: token
    )
)
```

The manual bearer header above is a transitional migration shape. Move token
ownership into `RefreshTokenPolicy`, then change the attribute to
`auth: .required` and remove the token property/header. Use `EndpointBuilder`
only for a request that is intentionally one-off or runtime-composed.
