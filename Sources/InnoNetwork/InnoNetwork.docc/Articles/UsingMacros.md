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
placeholders such as `{id}`. Placeholder values are passed through
``EndpointPathEncoding/percentEncodedSegment(_:)`` so each value stays within a
single path segment even when it contains spaces, slashes, or non-ASCII text.
Generated witnesses follow the access level of the attached type:

- `public` or `open` endpoint types receive `public` witnesses.
- `package` endpoint types receive `package` witnesses.
- default/internal endpoint types omit an explicit access modifier.

This keeps app-internal endpoints usable without accidentally emitting public
members inside an internal expansion while preserving the existing public
expansion for exported SDK endpoints.

The expansion emits the module-qualified call
`InnoNetwork.EndpointPathEncoding.percentEncodedSegment(...)` to avoid
ambiguity when consumer code imports another module that re-exports a same-named
type. Do not declare a nested type named `InnoNetwork` in scopes where
`@APIDefinition` is applied — it shadows the module reference and breaks the
generated path expression.

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

## Common failure cases

- Missing `typealias APIResponse` leaves the generated conformance incomplete.
- A placeholder such as `/users/{id}` requires a stored property named `id`.
- A nested type or local declaration named `InnoNetwork` can shadow the module
  used by the generated path encoder call.
- Public SDK endpoint types should be marked `public`; otherwise the generated
  witnesses intentionally stay internal and cannot satisfy exported clients.
