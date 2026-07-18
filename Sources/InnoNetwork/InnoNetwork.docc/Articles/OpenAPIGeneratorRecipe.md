# OpenAPI Generator workflow recipe

Drop a `swift-openapi-generator` output into a project that already
uses InnoNetwork without leaning on the generator's runtime client.

This article is the workflow companion to <doc:OpenAPIGeneratorAdapter>:
that one shows the `APIDefinition` wrapper API; this one shows where
the generator's files live and how to wire them in.

## Why generate the operation surface but keep InnoNetwork as the transport

The generator produces three layers from an OpenAPI document:

1. **Schemas** — `Codable` Swift types for every request and response
   payload.
2. **Operation descriptors** — one type per OpenAPI operation, with the
   HTTP method, path, and parameter shape baked in.
3. **A runtime client** — the type that turns those descriptors into
   actual HTTP requests.

InnoNetwork already covers (3): retry, refresh, coalescing, caching,
observability. Reusing the generator's runtime client means running
two transports in parallel and reconciling two sets of policy. The
recipe in this article keeps (1) and (2) — the parts that are
mechanical and tedious to maintain by hand — and routes everything
else through ``DefaultNetworkClient``.

## Project layout

```text
MyApp/
├── Sources/
│   ├── MyApp/
│   │   └── ...
│   └── MyAppOpenAPI/
│       ├── Generated/        # generator output, gitignored
│       │   ├── Client.swift
│       │   ├── Types.swift
│       │   └── Server.swift   # delete or unused
│       ├── openapi.yaml      # source-of-truth spec
│       └── openapi-generator-config.yaml
└── Package.swift
```

The generator runs at build time via the
`OpenAPIGenerator` SwiftPM build plugin. Only the schema and operation
files are consumed by application code; the generated client file can
be left in place or deleted.

## Wiring an operation through `APIDefinition`

For each generated operation, declare a thin `APIDefinition` wrapper
that re-uses the generated input and output types directly:

```swift
import InnoNetwork
import MyAppOpenAPI  // generator output target

@APIDefinition(method: .get, path: "/v1/users", auth: .anonymous)
struct ListUsers {
    typealias Parameter = Operations.ListUsers.Input
    typealias APIResponse = Operations.ListUsers.Output

    let parameters: Parameter?
}
```

Endpoint-specific concerns — interceptors, headers, retry overrides —
live on the wrapper, not on the generator output. Regenerating the
spec changes the input/output types but does not touch the wrapper's
networking policy.

## Avoiding generator drift

Two operational guardrails keep the wrapper layer cheap to maintain:

- **Pin the generator version** in `Package.swift` so a CI run cannot
  silently regenerate against a newer generator with different output
  conventions.
- **Run the generator on every CI build** rather than checking the
  output into git. Drift between `openapi.yaml` and the wrappers
  fails the build immediately because the generator would produce a
  type the wrapper no longer references.

## When to graduate to the SPI path

If an endpoint needs response-body access that the generator surfaces
through its runtime client (multipart streams, SSE bodies that are
not yet first-class in InnoNetwork), use the SPI integration in
<doc:OpenAPIGeneratorAdapter> instead. The SPI path is the supported
escape hatch for behaviour the wrapper recipe cannot express; both
paths can coexist in the same module.
