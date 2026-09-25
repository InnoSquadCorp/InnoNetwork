# openapi-to-innonetwork (6.0 preview)

Generates `APIDefinition`-conforming Swift structs from a JSON-encoded
OpenAPI 3 subset. Lives outside the root SwiftPM package so the
runtime library never resolves codegen dependencies.

## Status

**Preview.** InnoNetwork 6.0 includes this tool as a provisional starting point
so adopters with 100+ endpoint backends can avoid hand-rolling
`APIDefinition` structs. The tool has no Stable compatibility promise. The
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
| Session authentication | ✅ Root/operation HTTP bearer requirements → required, optional or anonymous; unsupported requirements fail generation |
| Named credentials | ✅ Header API key, opt-in query/cookie, bearer and scoped OAuth AND/OR via application-owned provider |
| Schema composition | ✅ Object `allOf`, named discriminated `oneOf`, nullable scalar/reference properties; see restrictions below |
| Path templating (`/users/{id}`) | ✅ Required scalar simple-style arguments, independently percent-encoded |
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

### 6.0 contracts and explicit boundaries

- Path parameters may be inherited from the path item and overridden by an
  operation. Required string/integer/boolean parameters using simple style
  become `path_<name>` constructor arguments. Each uses
  `EndpointPathEncoding.percentEncodedSegment`; slashes, percent signs and
  Unicode cannot become path structure. Missing, unused, optional, array/object,
  non-simple and query/header parameters fail generation.
- Root security is inherited unless an operation supplies `security`. An empty
  array means anonymous; an HTTP bearer requirement means `.required`; adding
  an empty requirement alternative means `.optional`. Configure the client's
  `RefreshTokenPolicy` to supply a single legacy bearer token. API keys, distinct
  bearer alternatives and mixed AND/OR generate `RequestSecurityProviding` with
  an explicit application-owned provider and HTTPS origin constructor argument.
  Query/cookie declarations require explicit `allowsQueryCredentials` or
  `allowsCookieCredentials` flags, even when selecting another OR branch.
  Credential-slot conflicts and reserved header names fail generation. Unknown
  schemes, basic auth and external references still fail rather than become
  anonymous. OAuth requirements preserve exact scopes and require provider-
  attested grants/expiry; optional `OAuthCredentialRefreshing` handles bounded
  renewal. This tool does not implement an OAuth login flow or IdP token store.
- Component object `allOf` flattens properties and unions required keys.
  Conflicting properties, non-object branches and composition cycles fail.
  Named `oneOf` components require local references plus a discriminator that
  is a required nonnullable string on each branch. Generated associated-value
  enums dispatch by tag, reject unknown tags and reject encoding a branch whose
  tag does not match its case. Explicit mappings or component names are supported.
- Nullable properties become optionals. Required nullable keys must still be
  present during decoding and are encoded as explicit null when nil. Nullable
  component roots/items, inline compositions, nondiscriminated `oneOf` and
  `anyOf` fail. Ordinary unstructured object properties retain `AnyCodable`.
- Generated Codable models are serialization models, not a complete JSON Schema
  validator (numeric bounds, patterns, additional-property constraints and all
  schema keywords are not enforced). Server variables, non-JSON content and
  general OpenAPI 3.1/JSON Schema coverage are outside this preview.

### Compatibility note

The published 4.0.0 baseline rejected path templates. Users migrating
from an earlier, untagged source snapshot may have generated literal `{name}`
placeholders; regenerate from declared path parameters or use a hand-written
`path` implementation. The historical release baseline and migration policy are
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
Generated type and file names are validated across schemas, operations,
and fallback models before output is created. Collisions fail with a
diagnostic instead of overwriting a file. Numeric, reserved, and Unicode
source names are mapped to valid Swift identifiers; multiline summaries
are emitted as separate documentation-comment lines.

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

A spec containing `/users/{id}` must declare a required scalar `id` path
parameter. It generates a `path_id` constructor argument. Choose a hand-written
`APIDefinition` or `swift-openapi-generator` when the documented subset is
insufficient; support for the entire OpenAPI specification is not implied.

## Tests

```bash
swift test
```

Covers operation expansion across HTTP verbs, sanitization of
non-alphanumeric `operationId` values, namespace collisions, and the
method-plus-path fallback when `operationId` is absent. Schema tests also
lock required vs. optional property rendering and `AnyCodable` fallback
generation for unsupported property shapes. The repository-level
`Scripts/test_openapi_generated_output.sh` runs the CLI on regression
fixtures and parses and typechecks the generated Swift output.

## See also

- [docs/CodeGeneration.md](../../docs/CodeGeneration.md) — when to
  use this tool vs handwriting `APIDefinition` structs.
- [Examples/GeneratedClientRecipe](../../Examples/GeneratedClientRecipe)
  — the Provisionally Stable SPI surface for richer codegen.
- [SwiftOpenAPIGeneratorPath.md](SwiftOpenAPIGeneratorPath.md) — 5.0
  integration guide for the shipped `InnoNetworkClientTransport` and
  `OpenAPIRequest` paths.
