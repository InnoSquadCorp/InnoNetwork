# Migration From Moya

Use this cookbook when a Moya `TargetType` file has become the shared API
surface and you want a smaller first step into InnoNetwork. Convert each case
to an explicit endpoint struct; let `@APIDefinition` derive only its repetitive
protocol witnesses.

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

## After: explicit endpoint structs

```swift
import Foundation
import InnoNetwork

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
struct GetUser {
    typealias APIResponse = User
    let id: Int

    var headers: HTTPHeaders { ["Accept": "application/json"] }
}

struct UpdateNameBody: Encodable, Sendable {
    let displayName: String
}

@APIDefinition(method: .patch, path: "/me", auth: .required)
struct UpdateName {
    typealias APIResponse = User

    let body: UpdateNameBody

    var headers: HTTPHeaders {
        ["Accept": "application/json",
         "Idempotency-Key": UUID().uuidString]
    }
}

let client = DefaultNetworkClient(
    configuration: .advanced(
        baseURL: URL(string: "https://api.example.com/v1")!,
        auth: AuthPack(refreshToken: refreshPolicy)
    )
)

let user = try await client.request(GetUser(id: 1))

let updated = try await client.request(
    UpdateName(body: UpdateNameBody(displayName: "Taylor"))
)
```

Convert one case at a time. If a Moya case has plugin-specific behaviour,
move that logic to `NetworkConfiguration` interceptors or keep it explicit on
the endpoint struct rather than recreating a large enum. Keep bearer-token
ownership in `RefreshTokenPolicy`; `auth: .required` prevents the update
request from being sent anonymously when that policy cannot provide a token.
