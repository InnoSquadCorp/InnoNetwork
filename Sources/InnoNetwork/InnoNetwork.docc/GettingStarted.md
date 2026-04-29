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

## Use `Endpoint` for simple calls

Use ``Endpoint`` when a request only needs method, path, query/body parameters,
headers, content type, acceptable status codes, and response decoding:

```swift
let users = try await client.request(
    Endpoint.get("/users")
        .query(["limit": 20])
        .decoding([User].self)
)
```

Keep a dedicated ``APIDefinition`` when the endpoint owns custom
interceptors, encoders/decoders, multipart upload behavior, or streaming.

## Request execution contract

Stay on ``NetworkClient/request(_:)`` for normal typed requests and
``NetworkClient/upload(_:)`` for multipart uploads.

Lower-level request execution hooks may appear in the source tree while the
package is being prepared, but they are not part of the 4.0.0 stable public
contract. Treat them as future integration candidates unless your wrapper owns
the source pin and migration budget.

## When to use advanced configuration

Stay on ``NetworkConfiguration/safeDefaults(baseURL:)`` unless you need to change one of these:

- retry policy semantics
- trust evaluation behavior
- event delivery policy
- metrics or observability reporters

For those cases, switch to ``NetworkConfiguration/advanced(baseURL:_:)`` and keep the tuning local to the integration that actually needs it.
