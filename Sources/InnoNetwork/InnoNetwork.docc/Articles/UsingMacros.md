# Using Macros

`InnoNetworkCodegen` is a separate package for compile-time endpoint helpers.
Importing only the root `InnoNetwork` package does not resolve, fetch, or build
`swift-syntax`. Macro users opt into `Packages/InnoNetworkCodegen` explicitly.

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

The first two arguments (`method`, `path`) must be passed positionally; only
the response metatype is labeled `as:`. Adding `method:` or `path:` labels is
rejected with a diagnostic so call sites stay consistent.

Keep hand-written ``APIDefinition`` types for endpoints that need custom
parameters, interceptors, multipart uploads, streaming, or non-standard
decoding. The macro package is provisionally stable in 4.0.0.
