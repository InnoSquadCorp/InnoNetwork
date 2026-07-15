# Getting Started

Build a client with safe defaults, model a named request as an explicit struct
with ``APIDefinition(method:path:auth:)``, and call it through
``DefaultNetworkClient``.

> Important: This page follows the unreleased 5.0 preview on `main`.
> `4.0.0` remains the latest tagged stable release. Pin a reviewed revision
> for preview evaluation and do not ship a moving branch dependency in
> production.

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

``NetworkConfiguration/safeDefaults(baseURL:)`` is the secure baseline for
prototypes, tests, and integrations that already own resilience policy
elsewhere. For app-facing production clients, use
``NetworkConfiguration/recommendedForProduction(baseURL:)`` to opt into the
production retry, circuit-breaker, idempotency-key, and body-size guardrails.

## Define a request

```swift
import InnoNetwork

struct User: Decodable, Sendable {
    let id: Int
    let name: String
}

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
struct GetUser {
    typealias APIResponse = User

    let id: Int
}
```

The endpoint remains an ordinary value type and the source of truth for its
contract. The default-enabled macro derives conformance, method,
percent-encoded path, `sessionAuthentication`, and the empty payload witnesses.
It requires `APIResponse` and an explicit `.anonymous`, `.optional`, or
`.required` auth choice instead of guessing either policy.

A stored `query` property derives payload witnesses for GET and HEAD. A stored
`body` property does so only for POST, PUT, PATCH, and DELETE. OPTIONS, CONNECT,
TRACE, custom, and dynamic methods require a complete `Parameter` +
`parameters` pair; custom headers, interceptors, transport, and decoding also
stay visible on the struct. See <doc:UsingMacros> for the complete expansion
and diagnostic contract.

## Execute the request

```swift
let user = try await client.request(GetUser(id: 1))
print(user.name)
```

## Use `EndpointBuilder` for runtime-composed calls

Use ``EndpointBuilder`` when a request is intentionally one-off or its method,
path, or response shape is assembled at runtime:

```swift
let users = try await client.request(
    EndpointBuilder<EmptyResponse>
        .get("/users")
        .authentication(.anonymous)
        .query(["limit": 20])
        .decoding([User].self)
)
```

Keep macro-assisted, explicit endpoint structs for the application's named API
catalog. Multipart and streaming endpoints use their dedicated definition
protocols.

Endpoint paths are appended after the configured base URL path even when they
start with `/`. Keep query values in a macro endpoint's `query` property, a
manual endpoint's `parameters`, or ``EndpointBuilder/query(_:)``. The macro
rejects a literal `?` or `#` at compile time; hand-written/runtime paths are
rejected as ``NetworkError/configuration(reason:)`` with
``NetworkConfigurationFailureReason/invalidRequest(_:)``.

The macro ships from `import InnoNetwork` through the default `Macros` package
trait. Consumers that never use it can request `traits: []`; this excludes the
macro API and compiler plug-in compilation, although SwiftPM can still resolve
or fetch manifest-level dependencies. Traits are unified per package across
the resolved graph, so another dependency enabling defaults can re-enable the
trait.

## Request execution contract

Stay on ``NetworkClient/request(_:)`` for normal typed requests and
``NetworkClient/upload(_:)`` for multipart uploads.

Low-level generated-client hooks are `@_spi(GeneratedClientSupport)`, outside
the draft 5.0 public contract, and may change at any time during the preview or
break in a minor release after 5.0 is tagged. Use them only when a wrapper owns
an exact source pin and migration budget. The root macro does not bridge or
expose this SPI.

## When to use advanced configuration

Use ``NetworkConfiguration/recommendedForProduction(baseURL:)`` for production
clients unless you need to change one of these:

- retry policy semantics
- trust evaluation behavior
- event delivery policy
- metrics or observability reporters

For those cases, switch to ``NetworkConfiguration/advanced(baseURL:resilience:auth:observability:cache:transport:)`` and keep the tuning local to the integration that actually needs it.
