# Apple swift-openapi-generator path (5.0 design note)

This document is the planning surface for the 5.0 migration that
re-positions `Tools/openapi-to-innonetwork` against
[apple/swift-openapi-generator](https://github.com/apple/swift-openapi-generator).
Nothing in this document changes 4.0.0 behaviour; it ships as
scaffolding so the 5.0 work has a single anchor to expand from.

## Why a path?

`Tools/openapi-to-innonetwork` covers the `paths.*.<verb>` happy path
(JSON / YAML input, `$ref` schemas, typed `Parameter` / `APIResponse`)
but explicitly punts on the harder OpenAPI surface:

- `oneOf` / `allOf` / discriminator emit `AnyCodable` fallbacks.
- Authentication scopes always serialize as `PublicAuthScope`, no
  mapping table.
- Server variables, parameter styles, and content negotiation past
  `application/json` are out of scope.

`apple/swift-openapi-generator` already ships polish for those
features. The 5.0 line should let adopters keep using its generator
output while letting the runtime transport layer remain InnoNetwork —
especially the resilience surface (retry, circuit breaker, response
cache, refresh token, request coalescing) that the generator's
default `URLSession` transport does not expose.

## Two non-exclusive surfaces

The migration is sketched as two surfaces, each independently
shippable:

1. **`InnoNetworkOpenAPI` (today)** — A 71-line adapter module that
   already implements `OpenAPIRestOperation` -> `APIDefinition` so
   any client with a "method, path, parameters, response" shape can
   plug into `DefaultNetworkClient.request(_:)` and inherit the full
   policy stack. The generated surface is the same one
   `apple/swift-openapi-generator` produces, so adopters can keep
   driving InnoNetwork with the apple-generator output without using
   `Tools/openapi-to-innonetwork` at all. This is the recommended
   path for 4.0.0 adopters who want to ship today.

2. **`InnoNetworkOpenAPITransport` (5.0 work)** — A separate
   transport-only adapter that conforms to
   `apple/swift-openapi-runtime`'s `ClientTransport` protocol and
   forwards into `DefaultNetworkClient`. This lets adopters use the
   `apple/swift-openapi-generator` build plugin verbatim while still
   reaching the InnoNetwork policy stack. The transport surface is
   smaller than the full `OpenAPIRestOperation` adapter (no auth
   scope phantom, no per-operation transport policy), but it is also
   the surface most existing apple-generator users already own.

The 5.0 design intent is that both modules co-exist. Adopters who
generate clients with `apple/swift-openapi-generator` pick the
transport. Adopters who generate clients with this Tools/ package or
who hand-write OpenAPI shims pick `InnoNetworkOpenAPI`.

## What ships in 4.0.0

- `Tools/openapi-to-innonetwork`: unchanged.
- `Sources/InnoNetworkOpenAPI` (`OpenAPIRestOperation`, `OpenAPIRequest`):
  unchanged.
- This document, marked as the **5.0 design surface**.

## What 5.0 will add

- A new SwiftPM target `InnoNetworkOpenAPITransport` that conforms to
  `ClientTransport` from `apple/swift-openapi-runtime`. Implementation
  walks the generator's `HTTPRequest` / `HTTPBody` types, builds an
  `URLRequest`, dispatches through `DefaultNetworkClient` with the
  caller's `NetworkConfiguration` injected, and unwraps the
  `Response.data` / status code into the runtime's `HTTPResponse`.
- `apple/swift-openapi-runtime` becomes a SwiftPM dependency on the
  new target only — runtime-only consumers of InnoNetwork still
  resolve zero external dependencies.
- DocC article walking through both surfaces and when to pick each.
- `Examples/GeneratedClientRecipe` gains a sibling that demonstrates
  the transport with the apple/swift-openapi-generator build plugin.

## Open questions for 5.0

- Operation-level transport overrides (multipart, streaming) need to
  be preserved when the apple-generator plugin emits a single
  `ClientTransport`. The likely answer is to expose a per-request
  hook on the transport's init.
- `ClientTransport` does not surface `acceptableStatusCodes`, so the
  transport will rely on the generator-emitted client's own
  status-code handling. Document the caveat in the migration article.
- Whether the transport should depend on `swift-http-types` directly
  or transitively through the apple runtime — depends on the runtime
  package's API stability ledger at the time the 5.0 line opens.

## Status indicator

This file is the only signal in the 4.0.0 source tree that the 5.0
work exists. When the 5.0 line opens, this document moves to
`docs/rfcs/InnoNetworkOpenAPITransport.md` and the implementation PR
links back here from the migration guide.
