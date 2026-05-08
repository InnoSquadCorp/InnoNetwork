# Code Generation for InnoNetwork

When you have more than ~30 endpoints, hand-rolling
`APIDefinition` structs becomes the bottleneck. This article
covers the two supported paths.

## When to use code generation

| Scenario | Recommendation |
| --- | --- |
| 5–30 endpoints, frequent ad-hoc tweaks | Hand-write `APIDefinition` structs or `EndpointBuilder` calls. |
| 30+ endpoints, OpenAPI spec is the source of truth | Use `Tools/openapi-to-innonetwork` (4.x preview). |
| Custom envelope or auth shape upstream of `APIDefinition` | Use the `@_spi(GeneratedClientSupport)` SPI surface. See `Examples/GeneratedClientRecipe`. |
| Apollo / GraphQL operations | Stay with Apollo iOS or `swift-openapi-generator`; an InnoNetwork adapter on top of either is on the 5.0+ roadmap. |

The 4.x preview tool accepts JSON or YAML input, emits Codable schema
structs for `components.schemas`, and wires typed `Parameter` /
`APIResponse` aliases when operations use `$ref`. It still always emits
`PublicAuthScope`; authenticated OpenAPI mapping is a follow-up.

## `Tools/openapi-to-innonetwork`

```bash
cd Tools/openapi-to-innonetwork
swift run openapi-to-innonetwork \
    --input /path/to/openapi.json \
    --output ../../Sources/MyAPI \
    --module-name MyAPI
```

The generator emits one Swift file per OpenAPI operation, each
containing an `APIDefinition`-conforming struct with
`EmptyParameter` and `EmptyResponse`. Adopters typically swap
those defaults with their own typed parameters / responses
during the first integration pass.

YAML input is out of scope for the 4.x preview to keep the tool
dependency-free. Convert with `yq -o=json` or
`python -c "import sys, yaml, json; json.dump(yaml.safe_load(sys.stdin), sys.stdout)"`
in the meantime.

For the full README and roadmap see
[Tools/openapi-to-innonetwork/README.md](../Tools/openapi-to-innonetwork/README.md).

## SPI route — `@_spi(GeneratedClientSupport)`

When the generated client needs to plug richer serialization or
decoding into the InnoNetwork retry / refresh / observability
machinery without going through `APIDefinition`, the SPI surface
is the right tool. It is documented in
[`API_STABILITY.md`](../API_STABILITY.md#spi) and exercised by
`Examples/GeneratedClientRecipe`. The SPI is best-effort across
minors, so adopters should pin the InnoNetwork revision they
generated against.

## See also

- [`Tools/openapi-to-innonetwork/README.md`](../Tools/openapi-to-innonetwork/README.md)
- [`Examples/GeneratedClientRecipe`](../Examples/GeneratedClientRecipe)
- [`API_STABILITY.md`](../API_STABILITY.md) — SPI surface and
  contract scope.
