# Request and response interceptors

Adapt every outgoing `URLRequest` and incoming ``Response`` from one place
or per `APIDefinition`, with a deterministic onion order.

## Overview

InnoNetwork exposes two interceptor protocols:

- ``RequestInterceptor`` — adapts a `URLRequest` before the transport runs.
- ``ResponseInterceptor`` — adapts a ``Response`` after the transport
  completes.

Each protocol has two attachment points:

- **Session-level**, on ``NetworkConfiguration/requestInterceptors`` and
  ``NetworkConfiguration/responseInterceptors``. These run for **every**
  request the client dispatches.
- **Per-request**, on ``APIDefinition/requestInterceptors`` and
  ``APIDefinition/responseInterceptors``. These run only for the specific
  endpoint that declares them.

Cross-cutting concerns such as tenant headers, distributed-tracing headers, and
request IDs belong on the session. Endpoint-specific overrides — a one-off
`X-Idempotency-Key`, a debug-build response rewriter — belong on the
``APIDefinition``.

## Onion order

Both kinds of interceptor run, but in different directions:

```text
Request:  configuration → APIDefinition → URLSession.data
Response: URLSession.data → APIDefinition → configuration
```

This is the same nesting other libraries call the **onion model**: the
outer (session) layer wraps the inner (endpoint) layer on the way in,
then unwinds in reverse on the way out. A session-level response
interceptor therefore observes the same response shape it would observe
under a session-only setup, regardless of how many endpoint interceptors
sit between it and the transport.

## Example: shared trace headers

```swift
struct TraceHeaders: RequestInterceptor {
    let traceStore: any TraceStore

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue(await traceStore.currentTraceID(), forHTTPHeaderField: "X-Trace-ID")
        return request
    }
}

let configuration = NetworkConfiguration.advanced(
    baseURL: URL(string: "https://api.example.com")!
) { builder in
    builder.requestInterceptors = [TraceHeaders(traceStore: traceStore)]
}
let client = DefaultNetworkClient(configuration: configuration)
```

Every request the client dispatches now carries an `X-Trace-ID` header
without each ``APIDefinition`` having to re-declare the interceptor.

## Example: endpoint-specific request ID

```swift
struct RequestIDStamper: RequestInterceptor {
    let prefix: String
    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue("\(prefix)-\(UUID().uuidString)", forHTTPHeaderField: "X-Request-ID")
        return request
    }
}

struct CreateOrder: APIDefinition {
    typealias Parameter = CreateOrderInput
    typealias APIResponse = CreateOrderOutput

    let parameters: CreateOrderInput?
    var method: HTTPMethod { .post }
    var path: String { "/orders" }

    var requestInterceptors: [RequestInterceptor] {
        [RequestIDStamper(prefix: "orders")]
    }
}
```

`CreateOrder` adds the request-ID header on top of whatever the
session-level chain already attached.

## Refresh tokens

Use ``RefreshTokenPolicy`` for current access-token application, `401`-driven
refresh, and replay. Keep ``RequestInterceptor`` implementations focused on
tenant headers, request IDs, request signatures, and other metadata that the
refresh policy does not own:

```swift
let refreshPolicy = RefreshTokenPolicy(
    currentToken: { try await tokenStore.currentAccessToken() },
    refreshToken: { try await authService.refreshAccessToken() }
)

let client = DefaultNetworkClient(
    configuration: .advanced(baseURL: apiBaseURL) { builder in
        builder.requestInterceptors = [TenantHeaderInterceptor()]
        builder.refreshTokenPolicy = refreshPolicy
    }
)
```

Refresh replay starts from the request after the session-level and endpoint
interceptor chains have run, then replaces only the authorization value through
the refresh policy. That preserves trace, tenant, and signing headers across
the replay attempt.

Header precedence is fixed as: library defaults, endpoint headers, automatic
body `Content-Type`, request interceptors, then ``RefreshTokenPolicy``
authorization. The last writer for a case-insensitive header name wins.

## Streaming responses

``DefaultNetworkClient/stream(_:)`` runs session-level
``NetworkConfiguration/requestInterceptors`` before opening the stream and
session-level ``NetworkConfiguration/responseInterceptors`` once the HTTP
headers arrive. The response passed to those response interceptors contains
status and header metadata only; ``Response/data`` is empty because the stream
body is decoded line-by-line afterward.

Do not use body-inspecting response interceptors for streaming payloads such as
SSE or NDJSON frames. Keep JSON error mapping, token-refresh bodies, and other
buffered-response concerns on ``DefaultNetworkClient/request(_:)`` or
``DefaultNetworkClient/upload(_:)``. Streaming endpoints also do not have
per-endpoint response interceptors; only configuration-level response
interceptors run for streams.

## Choosing where to put an interceptor

| Concern                        | Recommended slot                |
|--------------------------------|---------------------------------|
| Auth (Bearer, OAuth, mTLS)     | Session                         |
| Request IDs / tracing headers  | Session                         |
| Locale / device headers        | Session                         |
| Debug response logging         | Session                         |
| One-off `X-Idempotency-Key`    | ``APIDefinition``               |
| Endpoint-specific body shaping | ``APIDefinition``               |
| Test fakes / preview overrides | `InnoNetworkTestSupport.StubNetworkClient` |
| Refresh-token coordination     | Session (response) + retry policy |

When in doubt, prefer the session: it removes boilerplate and makes the
behaviour discoverable from a single configuration site.
