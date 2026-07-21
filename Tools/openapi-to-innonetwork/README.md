# openapi-to-innonetwork (5.x preview)

Generates `APIDefinition`-conforming Swift structs from a JSON-encoded
OpenAPI 3 subset. Lives outside the root SwiftPM package so the
runtime library never resolves codegen dependencies.

## Status

**Preview.** InnoNetwork 5.x includes this tool as a provisional starting point
so adopters with 100+ endpoint backends can avoid hand-rolling
`APIDefinition` structs. The tool has no Stable 5.x compatibility promise. The
current state covers the common case (JSON + YAML input, `components.schemas` → Codable
struct, request/response `$ref` → typed `Parameter` / `APIResponse`)
and tracks the remaining surface for follow-up work:

| Feature | Status |
| --- | --- |
| Input format | ✅ JSON + YAML (Yams) |
| Operation coverage | ✅ `paths.*.get/post/put/patch/delete` with `operationId`, `summary`, `requestBody`, `responses` |
| Generated shape | ✅ Typed `Parameter` / `APIResponse` from `$ref`; falls back to `EmptyParameter` / `EmptyResponse` when absent |
| Response status codes | ✅ `200`/`201` body schema; `202`/`204` → `EmptyResponse` |
| Schema property types | ✅ string / integer / number / boolean / array / `$ref` (incl. format hints: `int64`, `date-time`, `uri`) |
| Session authentication | ⚠️ always emits `SessionAuthentication.anonymous`; security-scheme mapping is a follow-up |
| Schema variants (oneOf / allOf / discriminator / nullable) | ⚠️ unsupported; properties using these generate compileable `AnyCodable` placeholders |
| Path templating (`/users/{id}`) | ❌ rejected at generation time — see "Scope" below |
| SPI integration | ⚠️ not used; the standard `APIDefinition` surface is the integration point |

## Scope: Subset of OpenAPI 3.x

The tool intentionally covers a narrow, opinionated subset of the
OpenAPI 3.x spec so the generated `APIDefinition` structs stay close to
the surface a hand-written InnoNetwork client would produce. The
boundaries are enforced at generation time, not silently degraded.

### Supported

- HTTP verbs: `get` / `post` / `put` / `patch` / `delete`
- Operation metadata: `operationId`, `summary`, `requestBody`, `responses`
- `$ref` schemas under `components.schemas` (one level of indirection)
- Property types: `string`, `integer` (incl. `int64`), `number`,
  `boolean`, `array`, `$ref` references; format hints `date-time` and
  `uri` round-trip to Swift types
- Required vs. optional property rendering
- Response status codes `200` / `201` (typed body), `202` / `204`
  (`EmptyResponse`)

### Unsupported (explicit)

- **Path templating** — paths containing `{name}` placeholders (e.g.
  `/users/{id}`) are rejected with a `GenerationError.unsupportedPath`
  diagnostic at generation time. Adopters who need template
  substitution should hand-roll the `path` property on the generated
  struct (delete the generator-emitted file and check in the
  hand-written variant). Silent emission was removed in 4.x because
  generated structs with raw `{id}` literals produced confusing runtime
  404s; failing the build surfaces the constraint at codegen time.
- **Schema composition**: `oneOf`, `allOf`, `anyOf`, `discriminator`,
  `nullable` — properties using these compose into compileable
  `AnyCodable` placeholders; you cannot recover the polymorphic shape
  from the generated output.
- **Server variables**, **security schemes**, **parameter `in: query`
  / `in: path` / `in: header` schemas**, **content types other than
  `application/json`** — out of scope for the 5.x preview.

Because security schemes are not interpreted, every generated operation
declares `sessionAuthentication` as `.anonymous`. Do not ship an authenticated
operation unchanged. Until configurable mapping exists, either replace that
operation with an app-owned `APIDefinition` or apply deterministic
post-processing after every generation to select `.optional` or `.required`.
The generator never infers this policy from path names, headers, or response
status codes.

### Compatibility note

The published 4.0.0 baseline already rejects path templates. Users migrating
from an earlier, untagged source snapshot may have generated literal `{name}`
placeholders; replace those files with a hand-written `path` implementation as
described in "Scope" above. The release baseline and migration policy are
recorded in [`docs/Migration-4.0.0.md`](../../docs/Migration-4.0.0.md); the 4.1
tombstone is not a released compatibility boundary.

Yams is scoped exclusively to this Tools/ package, so adopters who pull in
InnoNetwork as a library never resolve Yams.

## Usage

```bash
cd Tools/openapi-to-innonetwork

# JSON input
swift run openapi-to-innonetwork \
    --input openapi.json \
    --output ../../Sources/MyAPI \
    --module-name MyAPI

# YAML input (extension is autodetected)
swift run openapi-to-innonetwork \
    --input openapi.yaml \
    --output ../../Sources/MyAPI \
    --module-name MyAPI
```

The generator prints a one-line summary to stderr on success
(`openapi-to-innonetwork: wrote N file(s) to <path>`) and exits 1 with
a diagnostic on any I/O or parse failure.

## Generated output

For an operation:

```json
"/users": {
    "get": {
        "operationId": "listUsers",
        "summary": "List all users."
    }
}
```

The tool emits `ListUsers.swift`:

```swift
// Generated by openapi-to-innonetwork. DO NOT EDIT BY HAND.
// Module: MyAPI

import Foundation
import InnoNetwork

/// List all users.
public struct ListUsers: APIDefinition {
    public typealias Parameter = EmptyParameter
    public typealias APIResponse = EmptyResponse

    public var method: HTTPMethod { .get }
    public var path: String { "/users" }
    public var sessionAuthentication: SessionAuthentication { .anonymous }

    public init() {}
}
```

A spec containing `/users/{id}` would instead fail generation with
`GenerationError.unsupportedPath` — see the "Scope" section above for
the migration guidance.

The current 5.x preview still rejects path templating and does not promise a
delivery version for broader parser support. A future 5.x release may add more
schema features with an explicit changelog entry, but adopters should choose a
hand-written `APIDefinition` or `swift-openapi-generator` today when the
current subset is insufficient.

## Tests

```bash
swift test
```

Covers operation expansion across HTTP verbs, sanitization of
non-alphanumeric `operationId` values, and the
method-plus-path fallback when `operationId` is absent. Schema tests also
lock required vs. optional property rendering and `AnyCodable` fallback
generation for unsupported property shapes.

## See also

- [docs/CodeGeneration.md](../../docs/CodeGeneration.md) — when to
  use this tool vs handwriting `APIDefinition` structs.
- [Examples/GeneratedClientRecipe](../../Examples/GeneratedClientRecipe)
  — the Provisionally Stable SPI surface for richer codegen.
- [SwiftOpenAPIGeneratorPath.md](SwiftOpenAPIGeneratorPath.md) — 5.0
  integration guide for the shipped `InnoNetworkClientTransport` and
  `OpenAPIRequest` paths.
