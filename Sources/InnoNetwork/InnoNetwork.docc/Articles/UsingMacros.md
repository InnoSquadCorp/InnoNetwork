# Using Macros

Define an endpoint as an explicit value and let ``APIDefinition(method:path:auth:)``
derive only its repetitive protocol witnesses. The struct remains the source of
truth for the endpoint contract: its stored inputs and explicit `APIResponse`
show what goes in and what comes back.

```swift
import InnoNetwork

@APIDefinition(method: .get, path: "/users/{id}", auth: .public)
struct GetUser {
    typealias APIResponse = User

    let id: Int
}

let user = try await client.request(GetUser(id: 42))
```

The macro is part of the root `InnoNetwork` product. The package's default
`Macros` trait enables it, so macro users need neither another package nor
another import.

## What the macro owns

The macro adds ``APIDefinition`` conformance and derives:

- `method` and a percent-encoded `path`
- `Parameter` and `parameters` for the supported simple payload shape
- `Auth = AuthRequiredScope` when `auth: .required` is selected

It deliberately does **not** synthesize `APIResponse`, headers, interceptors,
signers, transport, decoding, or execution policies. Keep those decisions on
the endpoint struct when it owns them. Authentication is also mandatory at the
attribute: every endpoint must choose `.public` or `.required` rather than
silently inheriting a security policy.

Path placeholders must match stored properties declared directly on the
struct. Values pass through
``EndpointPathEncoding/percentEncodedSegment(_:)``, so a slash, space, percent
sign, or non-ASCII scalar stays inside one path segment.

## Query and body inference

A stored `query` property is the simple GET shape:

```swift
@APIDefinition(method: .get, path: "/users", auth: .public)
struct ListUsers {
    typealias APIResponse = [User]

    let query: ListUsersQuery
}
```

A stored `body` property is the simple non-GET shape:

```swift
@APIDefinition(method: .post, path: "/users", auth: .required)
struct CreateUser {
    typealias APIResponse = User

    let body: CreateUserRequest
}
```

An endpoint cannot infer both roles. GET bodies, non-GET query inference, and
dynamic method expressions are rejected because their transport meaning is not
safe to guess. Optional `body` or `query` aliases are supported; `nil` means no
payload.

For an advanced payload shape, declare the complete `Parameter` + `parameters`
pair. That pair is authoritative and turns off simple body/query inference:

```swift
@APIDefinition(method: .get, path: "/users/search", auth: .public)
struct SearchUsers {
    typealias APIResponse = [User]
    typealias Parameter = SearchPayload

    let filters: SearchPayload

    var parameters: Parameter? { filters }
    var transport: TransportPolicy<[User]> { .query() }
}
```

This escape hatch keeps custom encoding, computed payloads, and endpoint policy
explicit without giving up compile-time path and auth validation. Multipart
and streaming endpoints continue to use their dedicated protocols.

## Diagnostics are fail closed

`@APIDefinition` emits a compile error when the declaration would be ambiguous
or incomplete, including:

- attaching the macro to anything other than a struct
- omitting `typealias APIResponse`
- omitting `auth:` or passing anything other than `.public` / `.required`
- duplicating generated conformance, `method`, `path`, or `Auth` witnesses
- using a missing, optional, opaque, or unsupported generic path placeholder
- putting query/fragment text or an invalid percent escape in `path:`
- using computed, static, or lazy `body` / `query` properties in simple mode
- declaring only one half of the manual `Parameter` + `parameters` pair

Simple string interpolation in `path:` receives a Fix-It to use `{property}`
placeholder syntax. A redundant `typealias Parameter = EmptyParameter` emits a
warning because the macro already derives it for an empty request.

The 4.x `#endpoint` expression macro is removed in 5.0. For an unnamed or
runtime-composed request, use the stable ``EndpointBuilder`` API. For generated
OpenAPI clients, keep `swift-http-types` and OpenAPI Runtime integration behind
the optional `InnoNetworkOpenAPI` companion product rather than exposing those
types through the core endpoint contract.

## Disabling macro support

Consumers that never use macros can disable the default trait on the package
dependency:

```swift
dependencies: [
    .package(
        url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
        from: "5.0.0",
        traits: []
    )
]
```

With `traits: []`, the macro declaration is absent and the compiler plug-in
products are excluded from the target graph and compilation. SwiftPM still
resolves package-level manifest dependencies, so it may resolve or fetch the
`swift-syntax` source package even though it does not build the macro plug-in.
This is a SwiftPM manifest-resolution limitation, not a runtime dependency of
`InnoNetwork`. Traits are unified for each package across the resolved graph;
if another dependency enables the default `Macros` trait, it is enabled for
that shared package instance. A core-only graph must therefore request
`traits: []` consistently along every dependency path.
