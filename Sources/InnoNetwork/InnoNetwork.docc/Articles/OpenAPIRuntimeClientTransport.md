# OpenAPI Runtime ClientTransport

Use `InnoNetworkClientTransport` to dispatch generated
`swift-openapi-generator` clients through a URLSession that the host
application has already configured (timeouts, cache policy, cookie
storage, HTTP/3, etc.).

> Note: `InnoNetworkClientTransport`, `InnoNetworkClientTransportError`,
> `OpenAPIRequest`, `OpenAPIRestOperation`, and `OpenAPIAdapter` are
> declared in the `InnoNetworkOpenAPI` module. The names appear inline
> here because DocC's symbol-link syntax only resolves to symbols in the
> hosting module's catalog; cross-module references would render as
> unresolved links. Their headers contain the same usage notes via
> `///` documentation.

This adapter sits next to the existing `OpenAPIRequest` /
`OpenAPIRestOperation` pair. The two cover different directions:

| Need | Use |
|------|-----|
| Dispatch a hand-rolled or codegen-emitted `OpenAPIRestOperation` through ``DefaultNetworkClient``'s full interceptor / retry / cache pipeline. | `OpenAPIRequest` + ``DefaultNetworkClient`` |
| Hand a generated `OpenAPIRuntime.Client` (the one produced by `swift-openapi-generator`) the transport it needs, while reusing the URLSession the rest of your code already trusts. | `InnoNetworkClientTransport` |

`InnoNetworkClientTransport` deliberately mirrors the shape of
`swift-openapi-urlsession` so adopting it is a one-line type swap.

## Wiring a generated client

```swift
import OpenAPIRuntime
import InnoNetwork
import InnoNetworkOpenAPI
import GeneratedAPI  // the module produced by swift-openapi-generator

let session = URLSession(
    configuration: NetworkConfiguration
        .safeDefaults(baseURL: URL(string: "https://api.example.com")!)
        .makeURLSessionConfiguration()
)

let transport = InnoNetworkClientTransport(session: session)
let client = Client(
    serverURL: URL(string: "https://api.example.com")!,
    transport: transport
)

let response = try await client.getUser(.init(path: .init(id: 42)))
```

`makeURLSessionConfiguration()` carries the session-level timeout, cache,
and network-access defaults from ``NetworkConfiguration``. Cookie storage,
HTTP/3, TLS protocol bounds, proxy settings, and delegate-owned behavior
remain direct `URLSessionConfiguration` / `URLSession` choices:

```swift
let networkConfig = NetworkConfiguration.safeDefaults(baseURL: baseURL)
let sessionConfig = networkConfig.makeURLSessionConfiguration()
sessionConfig.httpCookieStorage = isolatedCookies
sessionConfig.assumesHTTP3Capable = true
sessionConfig.tlsMinimumSupportedProtocolVersion = .TLSv13

let session = URLSession(configuration: sessionConfig)
```

`NetworkConfiguration.trustPolicy` is evaluated by InnoNetwork's request
pipeline; it is not representable on `URLSessionConfiguration` and is not
copied into this bare generated-client transport. Use `OpenAPIRequest` +
``DefaultNetworkClient`` when a generated operation must use the full
InnoNetwork pipeline.

## Byte limits

The transport still collects outgoing request bodies before forwarding
them to URLSession. Incoming response bodies are returned as a streaming
`HTTPBody` backed by `URLSession.bytes(for:)`. Limits default to 50 MiB
in each direction; raise or lower them at the construction site:

```swift
let transport = InnoNetworkClientTransport(
    session: session,
    requestBodyByteLimit: 8 * 1024 * 1024,    // 8 MiB
    responseBodyByteLimit: 64 * 1024 * 1024   // 64 MiB
)
```

For response bodies with a known oversized `Content-Length`, `send(...)`
throws before returning the `HTTPBody`. For unknown-length responses, the
same `.responseBodyTooLarge(limit:received:)` error can be thrown later
while the generated client consumes the body stream.

## Error mapping

The transport surfaces four transport-only failures via
`InnoNetworkClientTransportError`:

- `.invalidRequestURL(baseURL:path:)` — the supplied `HTTPRequest.path`
  could not be combined with `baseURL` to form a valid URL. The
  generated client almost always produces a valid path; this case
  exists for hand-constructed requests.
- `.nonHTTPResponse(_:)` — URLSession returned a non-`HTTPURLResponse`
  (extremely rare; only happens with `file://` overrides or test
  doubles that bypass the URL loading system).
- `.invalidStatusCode(_:)` — the origin returned a status code that
  `HTTPResponse.Status` does not recognise. The generated client
  unwraps the status itself for normal 1xx/2xx/3xx/4xx/5xx responses.
- `.responseBodyTooLarge(limit:received:)` — the origin returned more
  bytes than `responseBodyByteLimit` permits. The transport raises this
  before returning the body when `Content-Length` proves the limit will be
  exceeded, or from the returned `HTTPBody` stream when the body length is
  only known during consumption.

Every other transport failure flows through as the underlying
`URLError` so the generated client's own error handling can branch on
it.

## When the InnoNetwork pipeline is needed instead

`InnoNetworkClientTransport` is intentionally a thin URLSession
wrapper. It does **not** route requests through ``DefaultNetworkClient``:
the pipeline expects ``APIDefinition`` shapes (typed parameters, typed
response, transport policy, interceptor chain) and the generated client
speaks `HTTPRequest` / `HTTPBody` directly.

When you need InnoNetwork's retry policy, circuit breaker, RFC 9111
cache adapter, refresh-token coordinator, or per-endpoint interceptors,
declare an `OpenAPIRestOperation` and dispatch through `OpenAPIRequest`
+ ``DefaultNetworkClient`` instead. Both pipelines can coexist in the
same app for different surfaces.

## Related

- ``NetworkConfiguration``
- ``DefaultNetworkClient``
- ``APIDefinition``
