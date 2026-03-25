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

## When to use `perform`

Stay on ``NetworkClient/request(_:)`` for normal typed requests and
``NetworkClient/upload(_:)`` for multipart uploads.

Reach for ``LowLevelNetworkClient/perform(executable:)`` when you are building a
higher-level networking layer that needs to:

- adapt its own request contract onto `InnoNetwork`
- keep custom serialization and decoding logic outside `APIDefinition`
- reuse `InnoNetwork` request building, retry coordination, trust handling, and observability

In other words, `perform(executable:)` is the public low-level execution hook on
`LowLevelNetworkClient`. `perform(_:)` remains available for typed request
definitions, but neither variant is the recommended default for normal
application call sites.

## When to use advanced configuration

Stay on ``NetworkConfiguration/safeDefaults(baseURL:)`` unless you need to change one of these:

- retry policy semantics
- trust evaluation behavior
- event delivery policy
- metrics or observability reporters

For those cases, switch to ``NetworkConfiguration/advanced(baseURL:_:)`` and keep the tuning local to the integration that actually needs it.
