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

Cross-cutting concerns — Bearer auth, distributed-tracing headers, request
IDs — belong on the session. Endpoint-specific overrides — a one-off
`X-Idempotency-Key`, a debug-build response rewriter — belong on the
``APIDefinition``.

## Onion order

Both kinds of interceptor run, but in different directions:

```
Request:  configuration → APIDefinition → URLSession.data
Response: URLSession.data → APIDefinition → configuration
```

This is the same nesting other libraries call the **onion model**: the
outer (session) layer wraps the inner (endpoint) layer on the way in,
then unwinds in reverse on the way out. A session-level response
interceptor therefore observes the same response shape it would observe
under a session-only setup, regardless of how many endpoint interceptors
sit between it and the transport.

## Example: shared Bearer auth

```swift
struct BearerAuth: RequestInterceptor {
    let tokenStore: any TokenStore

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        if let token = await tokenStore.current() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

let configuration = NetworkConfiguration.advanced(
    baseURL: URL(string: "https://api.example.com")!
) { builder in
    builder.requestInterceptors = [BearerAuth(tokenStore: tokenStore)]
}
let client = DefaultNetworkClient(configuration: configuration)
```

Every request the client dispatches now carries an `Authorization` header
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

## Refresh tokens (request → response → retry)

A 401-driven refresh interceptor is a common combination of both
protocols. The ``RequestInterceptor`` injects the current token; the
``ResponseInterceptor`` watches for 401s and triggers a refresh. The
``RetryPolicy`` then re-runs the same request so the refreshed token
reaches the new attempt.

```swift
struct AuthRefreshResponse: ResponseInterceptor {
    let tokenStore: any TokenStore

    func adapt(_ urlResponse: Response, request: URLRequest) async throws -> Response {
        if urlResponse.statusCode == 401 {
            await tokenStore.refresh()
            // Throwing forces the call to fail and the retry policy to re-issue
            // the request with the freshly minted token.
            throw NetworkError.statusCode(urlResponse)
        }
        return urlResponse
    }
}
```

Hook this onto the session and pair it with a ``RetryPolicy`` that
returns ``RetryDecision/retry`` for `401` once. The call site sees a
single successful response with no awareness of the refresh.

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
| Test fakes / preview overrides | ``APIDefinition``               |
| Refresh-token coordination     | Session (response) + retry policy |

When in doubt, prefer the session: it removes boilerplate and makes the
behaviour discoverable from a single configuration site.
