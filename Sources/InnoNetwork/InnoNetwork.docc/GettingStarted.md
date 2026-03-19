# Getting Started

Build a client with safe defaults, model a request with ``APIDefinition``, and call it through ``DefaultNetworkClient``.

## Create a client

```swift
import Foundation
import InnoNetwork

let client = DefaultNetworkClient(
    configuration: .safeDefaults(
        baseURL: URL(string: "https://api.example.com/v1")!
    )
)
```

## Define a request

```swift
import InnoNetwork

struct User: Decodable, Sendable {
    let id: Int
    let name: String
}

struct GetUser: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = User

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
}
```

## Execute the request

```swift
let user = try await client.request(GetUser())
print(user.name)
```

## When to use advanced configuration

Stay on ``NetworkConfiguration/safeDefaults(baseURL:)`` unless you need to change one of these:

- retry policy semantics
- trust evaluation behavior
- event delivery policy
- metrics or observability reporters

For those cases, switch to ``NetworkConfiguration/advanced(baseURL:_:)`` and keep the tuning local to the integration that actually needs it.

