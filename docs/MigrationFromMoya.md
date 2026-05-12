# Migration From Moya

Use this cookbook when a Moya `TargetType` file has become the shared API
surface and you want a smaller first step into InnoNetwork. Start with
`EndpointBuilder`; keep protocol-based endpoint types for operations that
really own transport or interceptor policy.

## Before: Moya target

```swift
import Moya

enum UserAPI {
    case detail(id: Int)
    case updateName(String)
}

extension UserAPI: TargetType {
    var baseURL: URL { URL(string: "https://api.example.com/v1")! }
    var path: String {
        switch self {
        case .detail(let id): return "/users/\(id)"
        case .updateName: return "/me"
        }
    }
    var method: Moya.Method {
        switch self {
        case .detail: return .get
        case .updateName: return .patch
        }
    }
    var task: Task {
        switch self {
        case .detail:
            return .requestPlain
        case .updateName(let name):
            return .requestJSONEncodable(["displayName": name])
        }
    }
    var headers: [String: String]? { ["Accept": "application/json"] }
}

let provider = MoyaProvider<UserAPI>()
let response = try await provider.request(.detail(id: 1))
let user = try JSONDecoder().decode(User.self, from: response.data)
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
        .get("/users/1")
        .header("Accept", value: "application/json")
        .decoding(User.self)
)

let token = currentAccessToken
let updated = try await client.request(
    EndpointBuilder<EmptyResponse, PublicAuthScope>
        .patch("/me")
        .body(["displayName": "Taylor"])
        .header("Authorization", value: "Bearer \(token)")
        .header("Idempotency-Key", value: UUID().uuidString)
        .decoding(User.self)
)
```

Convert one case at a time. If a Moya case has plugin-specific behaviour,
move that logic to `NetworkConfiguration` interceptors or a dedicated
`APIDefinition` rather than recreating a large enum immediately.
