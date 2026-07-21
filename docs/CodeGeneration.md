# Code Generation for InnoNetwork

When you have more than ~30 endpoints, hand-rolling `APIDefinition` structs
can become the bottleneck. The released 5.x contract supports three
distinct OpenAPI integration paths; choose based on the generated type shape
and whether the request must use the full InnoNetwork execution pipeline.

## Choose an integration path

| Scenario | Recommendation | Runtime behavior |
| --- | --- | --- |
| 5–30 endpoints, frequent ad-hoc tweaks | Hand-write `APIDefinition` structs or `EndpointBuilder` calls. | Full `DefaultNetworkClient` pipeline. |
| A narrow OpenAPI 3 subset is sufficient and you want generated `APIDefinition` types | Use the provisional `Tools/openapi-to-innonetwork` tool. | Generated requests use the full pipeline. |
| Generated or hand-written metadata can conform to `OpenAPIRestOperation` | Wrap the operation in `OpenAPIRequest` from `InnoNetworkOpenAPI`. | Full retry, interceptor, cache, trust, and observability pipeline. |
| An `apple/swift-openapi-generator` `Client` is already the application entry point | Supply `InnoNetworkClientTransport` from `InnoNetworkOpenAPI`. | Thin caller-owned `URLSession` transport only; no InnoNetwork retry, refresh, interceptor, cache, coalescing, circuit-breaker, signing, or trust pipeline. |
| Custom generated serialization upstream of `APIDefinition` | Use the `@_spi(GeneratedClientSupport)` SPI surface. | Full pipeline through a best-effort SPI contract. |
| Apollo / GraphQL operations | Stay with Apollo iOS. | `swift-openapi-generator` and the OpenAPI adapters do not generate or execute GraphQL operations. |

## `Tools/openapi-to-innonetwork`

The provisional 5.x tool accepts JSON or YAML input, emits Codable schema structs
for `components.schemas`, and wires typed `Parameter` / `APIResponse` aliases
when operations use `$ref`. It explicitly emits
`sessionAuthentication: SessionAuthentication { .anonymous }` for every
operation and rejects path templates; security-scheme mapping and broader
OpenAPI coverage remain follow-up work. The generator does not infer auth from
operation names, headers, or status codes. Replace auth-required operations
with app-owned definitions or run deterministic post-processing after every
generation before shipping them.

```bash
cd Tools/openapi-to-innonetwork
swift run openapi-to-innonetwork \
    --input /path/to/openapi.json \
    --output ../../Sources/MyAPI \
    --module-name MyAPI
```

The generator emits one Swift file per `components.schemas` entry before
emitting operation files. Operations without supported request or response
shapes fall back to `EmptyParameter` / `EmptyResponse` so adopters can fill the
gaps during integration.

JSON and YAML inputs are both supported. YAML decoding uses Yams inside the
standalone `Tools/` package. The root package does not resolve Yams or a code
generation plugin, although it does resolve `swift-openapi-runtime` for the
optional `InnoNetworkOpenAPI` product.

For the exact supported subset, see
[Tools/openapi-to-innonetwork/README.md](../Tools/openapi-to-innonetwork/README.md).

## `OpenAPIRestOperation` and `OpenAPIRequest`

Use this route when you can expose an operation as method, path, parameters,
response, headers, status codes, and transport policy. `OpenAPIRequest` adapts
that shape to `APIDefinition`, so execution goes through
`DefaultNetworkClient` and inherits the complete InnoNetwork policy stack.

This bridge does not make arbitrary `swift-openapi-generator` output conform
automatically. Add a small operation adapter yourself, or use the generated
client transport below when the generator-emitted `Client` must stay as-is.

## `InnoNetworkClientTransport`

`InnoNetworkClientTransport` conforms to `OpenAPIRuntime.ClientTransport` and
can be passed directly to a `swift-openapi-generator` client. It translates
`HTTPRequest` / `HTTPBody` to the caller-supplied `URLSession` and translates
the response back to OpenAPI runtime types.

The adapter intentionally does not route through `DefaultNetworkClient`.
Configure session-level behavior on the supplied `URLSession`; InnoNetwork
retry, auth refresh, interceptors, response cache, request coalescing, circuit
breaker, signing, and trust evaluation do not run on this path. Request and
response body limits default to 50 MiB and can be overridden at initialization.
The transport does retain the shared network URL boundary: it applies
`DefaultRedirectPolicy`, re-admits every automatic redirect target, and throws
`InnoNetworkClientTransportError.redirectRejected` instead of contacting a
rejected hop. Cross-origin hops strip original request headers and clear values
configured through `URLSessionConfiguration.httpAdditionalHeaders`. Supply a
default or ephemeral URLSession. Background sessions throw
`backgroundSessionUnsupported` before dispatch because Foundation follows their
redirects without consulting the task redirect delegate.

See
[`SwiftOpenAPIGeneratorPath.md`](../Tools/openapi-to-innonetwork/SwiftOpenAPIGeneratorPath.md)
for the selection and migration details.

## SPI route — `@_spi(GeneratedClientSupport)`

When the generated client needs richer serialization or decoding inside the
InnoNetwork retry / refresh / observability machinery without going through
`APIDefinition`, use the SPI surface documented in
[`API_STABILITY.md`](../API_STABILITY.md#spi) and exercised by
`Examples/GeneratedClientRecipe`. The SPI is best-effort across minors, so pin
the InnoNetwork revision used by the generator.

## See also

- [`Tools/openapi-to-innonetwork/README.md`](../Tools/openapi-to-innonetwork/README.md)
- [`Tools/openapi-to-innonetwork/SwiftOpenAPIGeneratorPath.md`](../Tools/openapi-to-innonetwork/SwiftOpenAPIGeneratorPath.md)
- [`Examples/GeneratedClientRecipe`](../Examples/GeneratedClientRecipe)
- [`API_STABILITY.md`](../API_STABILITY.md) — SPI surface and contract scope.
