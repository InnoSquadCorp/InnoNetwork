# Request and response interceptors

Adapt every outgoing `URLRequest` and incoming ``Response`` from one place
or per `APIDefinition`, with a deterministic onion order.

## Overview

InnoNetwork exposes two interceptor protocols:

- ``RequestInterceptor`` — adapts a `URLRequest` before the transport runs.
- ``ResponseInterceptor`` — adapts a ``Response`` after the transport
  completes.

Each protocol has two attachment points:

- **Session-level**, through `AuthPack(additionalRequestInterceptors:)` and
  `AuthPack(additionalResponseInterceptors:)`. These run for **every** request
  the client dispatches.
- **Per-request**, on ``APIDefinition/requestInterceptors`` and
  ``APIDefinition/responseInterceptors``. These run only for the specific
  endpoint that declares them.

Cross-cutting concerns such as tenant headers, distributed-tracing headers, and
request IDs belong on the session. Endpoint-specific overrides — a one-off
`Idempotency-Key`, a debug-build response rewriter — belong on the
``APIDefinition``.

## Onion order

Both kinds of interceptor run, but in different directions:

```text
Request:  configuration interceptor → APIDefinition interceptor → refresh token
          → configuration signer → APIDefinition signer → URLSession
Response: URLSession.data → APIDefinition → configuration
```

This is the same nesting other libraries call the **onion model**: the
outer (session) layer wraps the inner (endpoint) layer on the way in,
then unwinds in reverse on the way out. A session-level response
interceptor therefore observes the same response shape it would observe
under a session-only setup, regardless of how many endpoint interceptors
sit between it and the transport.

## Failure semantics

An interceptor that throws aborts the **current attempt** immediately:
no later interceptor in the same direction runs, the transport is
not invoked, and the response chain is skipped. The thrown error is
surfaced to the configured ``RetryPolicy`` exactly like a transport
error would be. The policy decides whether the executor runs another
attempt.

Two rules follow from that:

- Throw a ``NetworkError`` whose classification matches the desired
  retry behaviour. Use ``NetworkError/statusCode(_:)`` if you want the
  policy to treat the failure like a server-side rejection it might
  retry. For permanent rejections, throw a category the policy
  classifies as `.noRetry` (for example
  ``NetworkError/configuration(reason:)`` with
  ``NetworkConfigurationFailureReason/invalidRequest(_:)`` for a
  missing signing key).
- Errors that are *not* ``NetworkError`` are wrapped into
  ``NetworkError/underlying(_:_:)`` for you, so the policy still sees a
  uniform error shape. Conform domain-specific errors to your own
  category mapping inside ``RetryPolicy/shouldRetry(error:retryIndex:request:response:)``
  if you need finer control.

Interceptors run again on every retry, so transient adaptation failures can
recover naturally. Body-dependent signatures and signing nonces belong in
``RequestSigner``; signers also run on every retry and refresh replay, after
the final body is available.

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
    baseURL: URL(string: "https://api.example.com")!,
    auth: AuthPack(
        additionalRequestInterceptors: [TraceHeaders(traceStore: traceStore)]
    )
)
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

@APIDefinition(method: .post, path: "/orders", auth: .anonymous)
struct CreateOrder {
    typealias Parameter = CreateOrderInput
    typealias APIResponse = CreateOrderOutput

    let parameters: CreateOrderInput?
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
tenant headers, request IDs, and other unsigned metadata that the refresh
policy does not own. Use ``RequestSigner`` for request signatures:

```swift
let refreshPolicy = RefreshTokenPolicy(
    currentToken: { try await tokenStore.currentAccessToken() },
    refreshToken: { try await authService.refreshAccessToken() }
)

let client = DefaultNetworkClient(
    configuration: .advanced(
        baseURL: apiBaseURL,
        auth: AuthPack(
            refreshToken: refreshPolicy,
            additionalRequestInterceptors: [TenantHeaderInterceptor()]
        )
    )
)
```

Refresh replay starts from the request after the session-level and endpoint
interceptor chains have run, then replaces only the authorization value through
the refresh policy. That preserves trace and tenant headers. Request signers
then run again so the replay receives a signature over the final token, URL,
headers, and body.

Header precedence is fixed as: library defaults, endpoint headers, automatic
body `Content-Type`, request interceptors, then ``RefreshTokenPolicy``
authorization, then request signers. The last writer for a case-insensitive
header name wins.

When building headers manually, use ``HTTPHeaders/add(name:value:)`` only for
fields where repeated values are intentional. Use ``HTTPHeaders/update(name:value:)``,
subscript assignment, or `URLRequest.setValue(_:forHTTPHeaderField:)` for
single-value request fields such as `Authorization`, `Content-Type`, `Cookie`,
and `Host`. The `URLRequest.headers` and `URLSessionConfiguration.headers`
bridges apply those single-value names with last-write-wins semantics while
preserving repeatable header values.

## Streaming responses

``DefaultNetworkClient/stream(_:)`` runs session-level request interceptors
from ``AuthPack`` before opening the stream and session-level response
interceptors once the HTTP headers arrive. The response passed to those
response interceptors contains
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
| Session bearer / OAuth refresh | ``RefreshTokenPolicy``          |
| HMAC / request JWT / AWS SigV4 | ``RequestSigner``               |
| mTLS / server trust            | Session trust policy            |
| Request IDs / tracing headers  | Session                         |
| Locale / device headers        | Session                         |
| Debug response logging         | Session                         |
| One-off `Idempotency-Key`      | ``APIDefinition``               |
| Endpoint-specific body shaping | ``APIDefinition``               |
| Test fakes / preview overrides | `InnoNetworkTestSupport.StubNetworkClient` |
| Refresh-token coordination     | Session (response) + retry policy |

When in doubt, prefer the session: it removes boilerplate and makes the
behaviour discoverable from a single configuration site.
