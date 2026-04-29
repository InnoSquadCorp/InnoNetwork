# Using Macros

`InnoNetworkCodegen` is an optional product for compile-time endpoint helpers.
Importing only `InnoNetwork` keeps the core runtime path free of `swift-syntax`.

```swift
import InnoNetwork
import InnoNetworkCodegen

@APIDefinition(method: .get, path: "/users/{id}")
struct GetUser {
    typealias APIResponse = User

    let id: Int
}

let endpoint = #endpoint(.get, "/users/1", as: User.self)
```

The attached ``APIDefinition(method:path:)`` macro generates the conformance,
uses `EmptyParameter`, and interpolates stored properties that match path
placeholders such as `{id}`.

The ``endpoint(_:_:as:)`` expression macro expands to the fluent ``Endpoint``
API:

```swift
Endpoint<EmptyResponse>(method: .get, path: "/users/1")
    .decoding(User.self)
```

Keep hand-written ``APIDefinition`` types for endpoints that need custom
parameters, interceptors, multipart uploads, streaming, or non-standard
decoding. The macro product is provisionally stable in 4.0.0.
