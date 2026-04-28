# Retry decisions

Tune ``RetryPolicy`` so transient failures recover automatically without amplifying load on
unhealthy servers.

## Overview

A retry policy decides three things:

1. **Whether to retry** at all (``RetryDecision/retry`` vs ``RetryDecision/abort``).
2. **How long to wait** before retrying (delay, with optional jitter).
3. **When to stop retrying entirely** (per-request cap and absolute total cap).

InnoNetwork ships ``ExponentialBackoffRetryPolicy`` as the default. It honours the server's
`Retry-After` header (RFC 9110, both delta-seconds and HTTP-date forms) and clamps the
result to the policy's `maxDelay`.

## Choose a budget per session, not per request

`maxRetries` caps attempts for a single request. `maxTotalRetries` caps attempts across the
client's lifetime — and is **not** reset when the network monitor flips back to satisfied.
This is intentional: a flaky network should not turn a single user action into hundreds of
retries.

```swift
let policy = ExponentialBackoffRetryPolicy(
    maxRetries: 3,
    baseDelay: .milliseconds(500),
    maxDelay: .seconds(30),
    maxTotalRetries: 12
)
```

Pick `maxTotalRetries` based on the user-visible cost of a "slow but eventually-succeeds"
session, not on raw success probability. Ten retries of 30 seconds each is a five-minute
freeze.

## Honour Retry-After

When the server returns `429` or `503` with a `Retry-After` header, the policy uses the
header value instead of the computed backoff. The header is clamped to `maxDelay` so a
hostile or buggy server cannot pin the client for an hour.

```http
HTTP/1.1 429 Too Many Requests
Retry-After: 5
```

The next attempt fires after 5 seconds even if the exponential backoff for that attempt
number would have been larger.

## Streaming requests do not retry

`DefaultNetworkClient.stream(_:)` does not apply the retry policy — re-establishing a
streaming connection is a higher-level concern that depends on whether the protocol has
a notion of position or sequence number (Last-Event-ID for SSE, sequence cursor for
NDJSON, etc.). For SSE specifically, see the streaming resume policy on
``StreamingAPIDefinition``.

## Custom decisions

For policies that need access to the request, response, or attempt count, implement
``RetryPolicy`` directly:

```swift
struct CircuitBreakerRetryPolicy: RetryPolicy {
    let breaker: CircuitBreaker

    func shouldRetry(
        request: URLRequest,
        response: HTTPURLResponse?,
        error: Error?,
        attempt: Int
    ) async -> RetryDecision {
        guard breaker.allowsRequest(to: request.url) else {
            return .abort
        }
        guard attempt < 3, isTransient(response, error) else {
            return .abort
        }
        return .retry(delay: .milliseconds(500 * 1 << attempt))
    }
}
```

The decision-returning overload is preferred over the legacy `Bool` overload — it lets the
policy carry the delay alongside the retry decision in a single result.

## Related

- ``RetryPolicy``
- ``RetryDecision``
- ``ExponentialBackoffRetryPolicy``
