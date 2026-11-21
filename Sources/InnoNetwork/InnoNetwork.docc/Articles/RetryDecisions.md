# Retry decisions

Tune ``RetryPolicy`` so transient failures recover automatically without amplifying load on
unhealthy servers.

## Overview

A retry policy decides three things:

1. **Whether to retry** at all (``RetryDecision/retry`` vs ``RetryDecision/noRetry``).
2. **How long to wait** before retrying (delay, with optional jitter).
3. **When to stop retrying entirely** (per-request cap and absolute total cap).

InnoNetwork ships ``ExponentialBackoffRetryPolicy`` as the default. It honours the server's
`Retry-After` header (RFC 9110, both delta-seconds and HTTP-date forms) and caps the
hint at the policy's `maxRetryAfterDelay`.

## Bound every retry of one request

`maxRetries` caps consecutive retries of one logical request. A policy may restart that
count after a meaningful network change
(``RetryPolicy/shouldResetAttempts(afterNetworkChangeFrom:to:)``); the built-in policy does
so when the interface set or the reachability status changes. `maxTotalRetries` caps every
retry of the same logical request and is **not** reset when the network monitor flips back
to satisfied. This is intentional: a flaky network should not turn a single user action
into hundreds of retries. When `maxTotalRetries` is omitted it equals `maxRetries`.

Both values belong to one logical request. They are not shared across requests; bound a
whole host with ``CircuitBreakerPolicy`` instead.

```swift
let policy = ExponentialBackoffRetryPolicy(
    maxRetries: 3,
    maxTotalRetries: 12,
    retryDelay: 0.5,
    maxDelay: 30
)
```

Pick `maxTotalRetries` based on the user-visible cost of a "slow but eventually-succeeds"
request, not on raw success probability. Ten retries of 30 seconds each is a five-minute
freeze.

## Honour Retry-After

When the server returns `429` or `503` with a `Retry-After` header, the policy returns the
header value as a hint. The retry coordinator waits for the larger of that hint and the
computed backoff, so a server hint never shortens the policy's own delay. The hint is
capped at `maxRetryAfterDelay` (60 seconds by default; `maxDelay` when
`maxRetryAfterDelay` is `nil`) so a hostile or buggy server cannot pin the client for an
hour.

```http
HTTP/1.1 429 Too Many Requests
Retry-After: 5
```

When the computed backoff for that attempt is 1 second, the next attempt fires after
5 seconds. When the computed backoff is 8 seconds, it fires after 8 seconds.

## Client-side Request Pacing

``RateLimitExecutionPolicy`` is an experimental fixed-window admission policy
for APIs with a known client budget:

```swift
let pacing = RateLimitExecutionPolicy(maximumRequests: 10, per: .seconds(1))
let configuration = NetworkConfiguration.advanced(
    baseURL: apiBaseURL,
    resilience: ResiliencePack(customExecutionPolicies: [pacing])
)
```

The policy applies to transport attempts, so a retry consumes another slot.
It is cancellation-aware while waiting, but does not replace server-driven
`Retry-After` handling or distributed rate limiting.

## Idempotency defaults

The built-in ``ExponentialBackoffRetryPolicy`` is conservative by default:

- `GET`, `HEAD`, `OPTIONS`, and `TRACE` can retry automatically
- `POST`, upload, multipart, `PUT`, `PATCH`, and `DELETE` retry only when the
  originating request carries an `Idempotency-Key` header
- transport failures are still evaluated against the request method and headers
  before retrying

Use an idempotency key for any unsafe method where the server can deduplicate
duplicate submissions:

```swift
@APIDefinition(method: .post, path: "/orders", auth: .anonymous)
struct CreateOrder {
    typealias Parameter = CreateOrderInput
    typealias APIResponse = CreateOrderOutput

    let parameters: CreateOrderInput?
    var headers: HTTPHeaders {
        var headers = HTTPHeaders.default
        headers.add(name: "Idempotency-Key", value: "order-\(parameters?.clientID ?? "unknown")")
        return headers
    }
}
```

If a consumer already owns duplicate-write protection outside InnoNetwork and
needs the previous method-agnostic behaviour, opt in explicitly:

```swift
let configuration = NetworkConfiguration.advanced(
    baseURL: URL(string: "https://api.example.com")!,
    resilience: ResiliencePack(
        retry: ExponentialBackoffRetryPolicy(
            idempotencyPolicy: .methodAgnostic
        )
    )
)
```

## Which failures the built-in policy retries

``ExponentialBackoffRetryPolicy`` retries a failure only when it is transient,
the request passes the idempotency check below, and the attempt budget
remains. One rule decides transience, and ``NetworkError/isRetriableHint``,
the circuit breaker, and ``NetworkErrorSummary/recovery`` read the same rule:

| Failure | Retried |
|---------|---------|
| ``NetworkError/statusCode(_:)`` with `408`, `429`, or `5xx` | Yes |
| ``NetworkError/statusCode(_:)`` with any other status | No |
| ``NetworkError/reachability(_:_:_:)``, ``NetworkError/timeout(reason:underlying:)`` | Yes |
| ``NetworkError/underlying(_:_:)`` (an unclassified transport error) | Yes, unless its `URLError` cannot change on a replay: an App Transport Security block, a malformed or unsupported URL, a redirect loop, an untrusted certificate, a refused credential, or a local file or size limit |
| ``NetworkError/policyRejected(_:)`` — body limit, open circuit, full rate-limit or admission queue, non-HTTP response | No |
| ``NetworkError/authentication(_:)`` — a session that cannot be renewed, or a failed request credential | No |
| ``NetworkError/configuration(reason:)``, ``NetworkError/decoding(stage:underlying:response:)``, ``NetworkError/trustEvaluationFailed(_:)``, ``NetworkError/cancelled`` | No |

A policy rejection is a local decision and replaying the same request
reproduces it. A session that cannot be renewed is not repaired by sending
the request again. A refresh that failed for a reason that says nothing about
the session — a connectivity failure, a timeout, or a `408`, `429`, or `5xx`
from the refresh endpoint — keeps that failure's case and is retried like any
other transient failure; see <doc:AuthRefresh>. A credential provider whose
own transport fails transiently is treated the same way.

A `304 Not Modified` that cannot be reconciled with the stored response is
``NetworkError/underlying(_:_:)`` with domain `InnoNetwork.ResponseCache` and
is retried. The stored entry is removed before the error is reported, so the
replay is unconditional and receives a full response; see
<doc:CachingStrategies>. See <doc:ErrorClassification> for the complete
table.

## Wait for the network only after a connectivity failure

`waitsForNetworkChanges: true` makes a retry wait for the network path to
change, up to `networkChangeTimeout`, before the backoff delay. The wait
applies only when the failed attempt was a connectivity failure:
``NetworkError/reachability(_:_:_:)`` with any ``ReachabilityReason`` —
including ``ReachabilityReason/cellularDataUnavailable``, where joining Wi-Fi
is the cure — or an offline ``NetworkError/configuration(reason:)``. A retry
after a `503` or a timeout on a working network is never held back by this
setting. `URLError.cannotConnectToHost` is a connection timeout
(``TimeoutReason/connectionTimeout``), not a connectivity failure, so a retry
after it goes straight to the backoff delay.

```swift
let policy = ExponentialBackoffRetryPolicy(
    maxRetries: 3,
    waitsForNetworkChanges: true,
    networkChangeTimeout: 30
)
```

The retry coordinator performs the wait on the client's configured
``NetworkMonitoring`` (`ObservabilityPack(networkMonitor:)`). See
<doc:OfflineHandling>.

## Streaming requests retry only the handshake

`DefaultNetworkClient.stream(_:)` applies the retry policy to the handshake:
the request that has not yet delivered a body byte. A transient handshake
failure is retried under the same budget, idempotency, and network-wait rules
as a buffered request. A handshake rejected with a refreshable status (`401`
by default) on a session-authenticated stream is first replayed once with a
refreshed token. A handshake that ends because the stream's own
first-response or total budget ran out is not retried, whatever the policy;
see <doc:StreamingGuide>.

After the handshake is accepted the retry policy no longer applies.
Re-establishing a disconnected stream is a higher-level concern that depends
on whether the protocol has a notion of position or sequence number
(Last-Event-ID for SSE, sequence cursor for NDJSON, etc.). See the streaming
resume policy on ``StreamingAPIDefinition`` and <doc:StreamingGuide>.

## Custom decisions

For policies that need access to the request, response, or attempt count, implement
``RetryPolicy`` directly:

```swift
struct CircuitBreakerRetryPolicy: RetryPolicy {
    let maxRetries = 3
    let retryDelay: TimeInterval = 0.5
    let breaker: CircuitBreaker

    func shouldRetry(
        error: NetworkError,
        retryIndex: Int,
        request: URLRequest?,
        response: HTTPURLResponse?
    ) -> RetryDecision {
        guard breaker.allowsRequest(to: request?.url) else {
            return .noRetry
        }
        guard retryIndex < maxRetries, isTransient(response, error) else {
            return .noRetry
        }
        return .retryAfter(retryDelay * Double(1 << retryIndex))
    }
}
```

``RetryPolicy/shouldRetry(error:retryIndex:request:response:)`` is the only
retry-decision entry point. It is synchronous and returns a ``RetryDecision``,
so the policy carries the delay alongside the verdict in a single result.

A custom policy sees every ``NetworkError`` case, including
``NetworkError/policyRejected(_:)`` and ``NetworkError/authentication(_:)``.
Return ``RetryDecision/noRetry`` for them unless the policy has a specific
reason to replay; start from ``NetworkError/isRetriableHint`` to inherit the
built-in classification:

```swift
func isTransient(_ response: HTTPURLResponse?, _ error: NetworkError) -> Bool {
    error.isRetriableHint
}
```

## Related

- ``RetryPolicy``
- ``RetryDecision``
- ``RetryIdempotencyPolicy``
- ``ExponentialBackoffRetryPolicy``
