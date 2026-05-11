# Error classification

Map ``NetworkError`` cases to user-facing recovery flows without losing the original
context.

## Overview

`NetworkError` is exhaustive about transport failures. Unlike opaque single-string errors,
each case carries the structured information you need to decide whether to retry, surface
to the user, or escalate to crash reporting.

## Cases at a glance

| Case | Cause | Typical recovery |
|------|-------|------------------|
| ``NetworkError/configuration(reason:)`` with ``NetworkConfigurationFailureReason/invalidBaseURL(_:)`` | Misconfigured client. | Treat as a programmer error; assert in DEBUG. |
| ``NetworkError/configuration(reason:)`` with ``NetworkConfigurationFailureReason/invalidRequest(_:)`` | Request shape and policy mismatch. | Fix the API definition; never retry. |
| ``NetworkError/configuration(reason:)`` with ``NetworkConfigurationFailureReason/offline(_:)`` | The configured reachability policy knows the device is offline. | Surface offline state or defer non-interactive work. |
| ``NetworkError/statusCode(_:)`` | Server returned a non-acceptable status. | Branch on `.response.statusCode`; let `RetryPolicy` decide retries. |
| ``NetworkError/decoding(stage:underlying:response:)`` | Response failed to decode at a tagged pipeline stage (`.responseBody` for buffered bodies, `.streamFrame` for per-frame streaming decoders). | Surface to the user; consider feature flagging the endpoint. Decoding failures are terminal — `isDecodingFailure` makes the rule explicit in custom retry policies. |
| ``NetworkError/reachability(_:_:_:)`` | DNS, offline, or dropped-connection failure classified from `URLError`. | Treat as network reachability; retry when the request is safe and the policy budget allows. |
| ``NetworkError/underlying(_:)`` | Foundation/URLSession error not classified above (including the rare non-`HTTPURLResponse` path, which is wrapped with code `3002`). | Inspect `SendableUnderlyingError.code` for deeper triage. |
| ``NetworkError/trustEvaluationFailed(_:)`` | TLS pinning or custom trust evaluator rejected the chain. | Surface to the user; do not auto-retry. |
| ``NetworkError/cancelled`` | `Task` cancellation or `cancelAll()`. | Honour silently — caller wanted to stop. |
| ``NetworkError/timeout(_:)`` | Request, resource, or connection timed out. | Apply retry policy if budget allows. |

## Recipe: branch on classification, not raw code

```swift
do {
    let user = try await client.request(GetUser())
    return .success(user)
} catch {
    switch error {
    case .cancelled:
        return .cancelled

    case .timeout:
        return .recoverableNetwork

    case .reachability(.notConnectedToInternet, _, _):
        return .offline

    case .statusCode(let response) where (500...599).contains(response.statusCode):
        return .recoverableServer

    case .statusCode(let response) where response.statusCode == 401:
        return .reauthenticate

    case .configuration(reason: .offline):
        return .offline

    case .trustEvaluationFailed:
        return .securityFailure  // never retry automatically

    default:
        return .failure(error)
    }
}
```

The point is that you classify on **case + structured payload** rather than re-parsing
strings. Two screens away from the call site, this stays robust to library changes.

## Failure payload capture

`NetworkError.decoding(stage:, underlying:, response:)` carries the `Response` for
the failed decode. By default, `response.data` is redacted to empty data before the
error is surfaced.
The original response body is preserved **only** when the consumer opts in via
`NetworkConfiguration.captureFailurePayload = true`. Keep that flag off in production
to avoid leaking PII into crash reports, analytics, or logs.

## NSError bridging

`NetworkError` bridges through the stable `InnoNetwork.NetworkError` NSError
domain. The 4.x line keeps numeric codes stable so observability pipelines can
group failures without parsing localized strings. Underlying Foundation errors
are preserved inside ``SendableUnderlyingError`` for `.underlying` and timeout
cases, while status-code failures keep the structured ``Response`` metadata.

## Cancellation is not a failure

`NetworkError.cancelled` is the **only** terminal request outcome that is also
expected. Never report it as an error in analytics or crash logs; it is the
contract for user-initiated cancellation, logout cleanup, and `cancelAll()`.

Across products, cancellation is terminal and non-retryable:

- typed requests, uploads, and streams surface ``NetworkError/cancelled``
- stale-while-revalidate background cancellation is ignored because the caller
  already received a cached value
- downloads transition to `DownloadState.cancelled` and publish a state event
- websockets transition to `WebSocketState.cancelled` and emit a cancellation
  error event where observers are still attached

## Related

- ``NetworkError``
- ``SendableUnderlyingError``
- ``NetworkConfiguration``
