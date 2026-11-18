# Error classification

Map ``NetworkError`` cases to user-facing recovery flows without losing the original
context.

## Overview

``NetworkError`` is the only error type the library surfaces: `request(_:)`,
`upload(_:)`, and ``NetworkOperation/value()`` throw it, and a `stream(_:)`
sequence fails with it.
Unlike opaque single-string errors, each case carries the structured information you need to
decide whether to retry, surface to the user, or escalate to crash reporting.

For most app-layer routing, start with the coarse helpers:
``NetworkError/category``, ``NetworkError/isRetriableHint``, and
``NetworkError/isUserVisible``. They keep UI, logging, and retry-affordance
code out of exhaustive `switch` statements while preserving the full
``NetworkError`` payload when deeper diagnostics are needed. When a failure has
to leave the call site — into view state, analytics, or a log — take its
payload-free ``NetworkError/summary``.

## Cases at a glance

| Case | Cause | Typical recovery |
|------|-------|------------------|
| ``NetworkError/configuration(reason:)`` with ``NetworkConfigurationFailureReason/invalidBaseURL(_:)`` | Misconfigured client. | Treat as a programmer error; assert in DEBUG. |
| ``NetworkError/configuration(reason:)`` with ``NetworkConfigurationFailureReason/invalidRequest(_:)`` | Request shape and policy mismatch. | Fix the API definition; never retry. |
| ``NetworkError/configuration(reason:)`` with ``NetworkConfigurationFailureReason/invalidPayload(_:)`` | A binary request codec or its byte budget rejected local input. | Fix the encoder or the budget; never retry. |
| ``NetworkError/configuration(reason:)`` with ``NetworkConfigurationFailureReason/offline(_:)`` | The configured reachability policy knows the device is offline. | Surface offline state or defer non-interactive work. |
| ``NetworkError/statusCode(_:)`` | Server returned a non-acceptable status. | Branch on `.response.statusCode`; let `RetryPolicy` decide retries. |
| ``NetworkError/decoding(stage:underlying:response:)`` | Response failed to decode at a tagged pipeline stage (`.responseBody` for buffered bodies, `.streamFrame` for per-frame streaming decoders). | Surface to the user; consider feature flagging the endpoint. Decoding failures are terminal — `isDecodingFailure` makes the rule explicit in custom retry policies. |
| ``NetworkError/reachability(_:_:_:)`` | DNS, offline, dropped-connection, or unavailable-cellular-data failure classified from `URLError`. See ``ReachabilityReason``. | Treat as network reachability; retry when the request is safe and the policy budget allows. |
| ``NetworkError/underlying(_:_:)`` | A transport error the built-in mapper did not classify, or a `304 Not Modified` that cannot be reconciled with the stored response (domain `InnoNetwork.ResponseCache`, code `304`). | Inspect `SendableUnderlyingError.domain` and `.code` for deeper triage. |
| ``NetworkError/trustEvaluationFailed(_:)`` | TLS pinning or custom trust evaluator rejected the chain. | Surface to the user; do not auto-retry. |
| ``NetworkError/cancelled`` | `Task` cancellation or `cancelAll()`. | Honour silently — caller wanted to stop. |
| ``NetworkError/timeout(reason:underlying:)`` | Request, resource, or connection timed out, or the ``NetworkOperationDeadline`` of an operation expired (``TimeoutReason/operationDeadline(_:)``). | Apply retry policy if budget allows. |
| ``NetworkError/policyRejected(_:)`` | A locally configured policy declined to send, continue, or accept the exchange. See ``NetworkPolicyRejection``. | Do not retry the same request immediately; it gives the same result. |
| ``NetworkError/authentication(_:)`` | The session cannot be renewed, or a named request credential could not be selected, acquired, or applied. See ``NetworkAuthenticationFailure``. | Ask the user to sign in again, or fix the credential provider; never retried automatically. |

### Reachability reasons

``NetworkError/reachability(_:_:_:)`` and an offline
``NetworkError/configuration(reason:)`` are the library's connectivity
failures: the device has no usable route to the host, and a network path
change can cure it. With ``RetryPolicy/waitsForNetworkChanges``, a retry waits
for a path change only after them, and ``NetworkErrorSummary/recovery`` recommends
``NetworkRecoveryDisposition/waitForConnectivity`` for an offline failure, and
for a reachability failure when the request may be replayed. Download retries
use the same `URLError` table.

| Reason | Produced from |
|--------|---------------|
| ``ReachabilityReason/notConnectedToInternet`` | `URLError.notConnectedToInternet` |
| ``ReachabilityReason/dnsLookupFailed`` | `URLError.dnsLookupFailed` |
| ``ReachabilityReason/cannotFindHost`` | `URLError.cannotFindHost` |
| ``ReachabilityReason/networkConnectionLost`` | `URLError.networkConnectionLost` |
| ``ReachabilityReason/cellularDataUnavailable`` | `URLError.dataNotAllowed`, `URLError.internationalRoamingOff`, `URLError.callIsActive` |

The underlying ``SendableUnderlyingError`` keeps the exact `URLError` code, so
`URLError.Code(rawValue: underlying.code)` still tells the three cellular codes
apart. `URLError.cannotConnectToHost` is not a reachability failure; it is
``NetworkError/timeout(reason:underlying:)`` with
``TimeoutReason/connectionTimeout``. A `switch` over ``ReachabilityReason``
without `default` must handle `.cellularDataUnavailable`, which 7.0 added.

### Policy rejections

``NetworkError/policyRejected(_:)`` says nothing about the server's health.
The built-in retry policy never retries it and the circuit breaker never
counts it against the host.

| Rejection | Cause | Stable code |
|-----------|-------|-------------|
| ``NetworkPolicyRejection/responseBodyLimitExceeded(limitBytes:observedBytes:)`` | The response body is larger than the ``ResponseBodyBufferingPolicy`` limit. `observedBytes` is the collected size, or the declared `Content-Length` when the response was rejected before its body was read. | `4003` |
| ``NetworkPolicyRejection/circuitOpen(_:)`` | The circuit breaker for the request's host is open. The payload is a ``CircuitBreakerOpenError`` with `host` and `retryAfter`. | `4011` |
| ``NetworkPolicyRejection/rateLimitQueueFull`` | The bounded rate-limit queue is full. | `4008` |
| ``NetworkPolicyRejection/rateLimitScopeLimitReached`` | The bounded rate-limit scope registry is full. | `4009` |
| ``NetworkPolicyRejection/admissionQueueFull`` | The bounded request-admission queue is full. | `4006` |
| ``NetworkPolicyRejection/admissionWaitExpired`` | The request waited in the admission queue past its deadline. | `4007` |
| ``NetworkPolicyRejection/nonHTTPResponse`` | The transport delivered a response that is not HTTP. | `3002` |

### Authentication failures

``NetworkError/authentication(_:)`` means the request could not be
authenticated before or after transport. A `401` that the server returns after
a successful refresh stays ``NetworkError/statusCode(_:)``.

| Failure | Cause | Stable code |
|---------|-------|-------------|
| ``NetworkAuthenticationFailure/refreshFailed(_:)`` | The session refresh showed that the session cannot be renewed: the refresh request was rejected with a status that is not transient (for example `400 invalid_grant`, `401`, `403`, or `404`) or with a credential-rejection `URLError` such as `.userAuthenticationRequired`, the token response could not be decoded, or the refresh closure threw an error of the application's own type. The payload is the error the refresh operation produced. | `6001` |
| ``NetworkAuthenticationFailure/credential(_:)`` | A named request credential failed. The payload is a secret-free ``RequestSecurityFailure``. | `6002` |

The rule is the same for every refresh: the replay after a refresh status and
the proactive refresh of a `.required` request that has no token yet. A
refresh that failed for a reason that says nothing about the session keeps its
own case, because the session may still be valid: cancellation, a connectivity
failure, a timeout, a `408`, `429`, or `5xx` from the refresh endpoint (the
``NetworkError/statusCode(_:)`` then carries the refresh endpoint's response,
but never the refresh request, whose body or headers hold the refresh token),
an unclassified transport error, a configuration failure including an offline
device, a local policy rejection such as an open circuit for the token host,
or a trust failure. Only an error that comes from a transport — a
``NetworkError`` or a `URLError` — can count as transient, and a `URLError`
that reports a rejected credential (`.userAuthenticationRequired`,
`.userCancelledAuthentication`, `.clientCertificateRejected`, or
`.clientCertificateRequired`) never does; any other error the refresh closure
throws becomes `.refreshFailed`. The failures that keep their own case follow
the ordinary retry and recovery rules. See <doc:AuthRefresh>.

A named credential follows the same rule. When a credential provider's own
transport fails transiently — a `URLError` other than a credential rejection,
or a ``NetworkError`` such as a connectivity failure or a timeout — the request
reports that failure's secret-free classification, for example
``NetworkError/reachability(_:_:_:)`` whose underlying error keeps the domain
and code with the message "Credential-protected transport failed.", instead of
``RequestSecurityFailure/credentialUnavailable`` or
``RequestSecurityFailure/refreshFailed``. A renewal stopped by a local policy
rejection, a trust failure, or a configuration failure of the provider's own
transport keeps that classification too, as a session refresh does, instead of
asking the user to sign in. A transient HTTP status from a
provider still becomes `.credentialUnavailable`, because a status would expose
the provider's response. A failure while preparing a named credential is never
counted against the request's host by the circuit breaker. See
<doc:RequestCredentials>.

## One classification for retry, circuit breaker, and recovery

One rule decides whether a failure is transient. ``NetworkError/isRetriableHint``,
``ExponentialBackoffRetryPolicy``, the circuit breaker, and
``NetworkErrorSummary/recovery`` all read it, so a failure cannot be transient
for one of them and terminal for another.

| Case | ``NetworkError/category`` | Transient | Counts toward the circuit breaker |
|------|---------------------------|-----------|-----------------------------------|
| `.statusCode` with `5xx` | `.statusCode` | Yes | Yes |
| `.statusCode` with `408` or `429` | `.statusCode` | Yes | No; a `4xx` response is excluded from the rolling window |
| `.statusCode` with any other status | `.statusCode` | No | No |
| `.underlying` (not a cancellation) | `.transport` | Yes, except a deterministic `URLError` (below) | Yes, except a deterministic `URLError` and an unreconcilable `304`, which is raised after the `304` was recorded as a success. A TLS failure, including a deterministic certificate failure, counts only when the policy counts transport-security failures |
| `.reachability` | `.reachability` | Yes | Yes, except `.notConnectedToInternet` and `.cellularDataUnavailable` |
| `.timeout` | `.timeout` | Yes | Yes |
| `.trustEvaluationFailed` | `.trust` | No | Only when ``CircuitBreakerPolicy/countsTransportSecurityFailures`` is `true` |
| `.configuration` | `.configuration` | No | No |
| `.decoding` | `.decoding` | No | No |
| `.cancelled` | `.cancellation` | No | No |
| `.policyRejected` | `.policy` | No | No |
| `.authentication` | `.authentication` | No | No |

A deterministic `URLError` is one whose outcome replaying the same request
cannot change: App Transport Security blocked the request
(`.appTransportSecurityRequiresSecureConnection`), the URL is malformed or
unsupported (`.badURL`, `.unsupportedURL`), the redirects loop or lead nowhere
(`.httpTooManyRedirects`, `.redirectToNonExistentLocation`), the system does
not trust the server certificate or refused the client certificate
(`.serverCertificateUntrusted`, `.serverCertificateHasBadDate`,
`.serverCertificateNotYetValid`, `.serverCertificateHasUnknownRoot`,
`.clientCertificateRejected`, `.clientCertificateRequired`), the server
refused the credential (`.userAuthenticationRequired`,
`.userCancelledAuthentication`), or a local file or size limit failed
(`.fileDoesNotExist`, `.fileIsDirectory`, `.noPermissionsToReadFile`,
`.dataLengthExceedsMaximum`). The built-in retry policy does not retry it, and
the circuit breaker does not count it, except that a certificate failure
counts when ``CircuitBreakerPolicy/countsTransportSecurityFailures`` is
`true`, like any other TLS failure.

The breaker column describes failures of the request's own exchange. A failure
raised while a named request credential is acquired, renewed, or signed is not
counted, whatever its case, and neither is a failed session refresh. A device
with no usable network path — ``ReachabilityReason/notConnectedToInternet`` or
``ReachabilityReason/cellularDataUnavailable`` — is not evidence about any one
host either: counting it would open the circuit of every host used while
offline, and the first requests after reconnecting would be rejected.

``NetworkError/isRetriableHint`` answers only whether the error class is
usually transient. It does not override ``RetryPolicy``, which also checks the
request method, the idempotency key, and the attempt budget.

## Recipe: branch on classification first

```swift
func presentation(for error: NetworkError) -> ErrorPresentation {
    switch error.category {
    case .cancellation:
        return .silent
    case .configuration:
        return error.isUserVisible ? .offline : .developerIssue
    case .reachability, .timeout, .transport:
        return error.isRetriableHint ? .retryableNetwork : .networkFailure
    case .statusCode:
        return error.isRetriableHint ? .retryableServer : .serverRejected
    case .decoding:
        return .unexpectedResponse
    case .trust:
        return .securityFailure
    case .policy:
        return .locallyRejected  // a retry gives the same result
    case .authentication:
        // Only an expired session or credential needs the user. A credential
        // contract the code got wrong is not user-visible.
        if error.summary.recovery == .reauthenticate { return .signInRequired }
        return error.isUserVisible ? .credentialUnavailable : .developerIssue
    }
}
```

## Recipe: branch on structured payloads when needed

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

    case .reachability(.cellularDataUnavailable, _, _):
        return .cellularDataOff  // joining Wi-Fi can cure it

    case .statusCode(let response) where (500...599).contains(response.statusCode):
        return .recoverableServer

    case .statusCode(let response) where response.statusCode == 401:
        return .reauthenticate

    case .authentication(.refreshFailed):
        return .reauthenticate  // the session cannot be renewed

    case .policyRejected(.responseBodyLimitExceeded(let limitBytes, let observedBytes)):
        return .responseTooLarge(limit: limitBytes, observed: observedBytes)

    case .policyRejected(.circuitOpen(let open)):
        return .temporarilyUnavailable(retryAfter: open.retryAfter)

    case .configuration(reason: .offline):
        return .offline

    case .trustEvaluationFailed:
        return .securityFailure  // never retry automatically

    default:
        return .failure(error)
    }
}
```

The point is that you classify on **helper bucket, or case + structured
payload** rather than re-parsing strings. Two screens away from the call site,
this stays robust to library changes. A `switch` over ``NetworkError`` or
``NetworkErrorCategory`` without `default` must list every case, including
`.policyRejected` and `.authentication`, and `.policy` and `.authentication`;
a `switch` over ``ReachabilityReason`` without `default` must list
`.cellularDataUnavailable`.

## Recipe: keep a payload-free summary

``NetworkErrorSummary`` keeps the category, the stable numeric code, the HTTP
status, and a recommended recovery — and nothing else. It carries no response
body, headers, URL, or underlying error text, so it is safe to store in view
state, compare in tests, or send to analytics.

```swift
do {
    let user = try await client.request(GetUser())
    render(user)
} catch {
    let summary = error.summary
    analytics.record(category: summary.category, code: summary.code, status: summary.statusCode)
}
```

``NetworkError/summary`` has no request context, so it cannot know whether a
replay is safe. For a failure that followed transport it reports
``NetworkRecoveryDisposition/doNotRetry`` instead of `.retry` or
`.waitForConnectivity`, and it reports
``NetworkRecoveryDisposition/reauthenticate`` only for an explicit
``NetworkError/authentication(_:)`` failure. Supply the context with
``NetworkError/summary(method:authentication:replaySafety:)``, or let an
operation supply it:

```swift
let operation = client.start(GetUser())
do {
    let user = try await operation.value()
    render(user)
} catch {
    // The operation knows the method, authentication, and replay safety.
    let summary = await operation.failureSummary() ?? error.summary
    switch summary.recovery {
    case .retry: offerRetry()  // the caller still owns the attempt budget
    case .waitForConnectivity: showOfflineState()
    case .reauthenticate: presentSignIn()
    case .doNotRetry, .none: showFailure(summary.description)
    }
}
```

The same summary arrives on the operation's event stream as
``NetworkOperationEvent/failed(id:summary:)``.

## Failure payload capture

`NetworkError.decoding(stage:, underlying:, response:)` carries the `Response` for
the failed decode. By default, `response.data` is redacted to empty data before the
error is surfaced.
The original response body is preserved **only** when the consumer opts in via
`CachePack(captureFailurePayload: true)` in an advanced configuration. Keep
that flag off in production to avoid leaking PII into crash reports,
analytics, or logs.

## NSError bridging

`NetworkError` bridges through the stable `com.innosquad.innonetwork` NSError
domain. The 6.1.1 contract uses stable numeric codes so observability pipelines
can group failures without
parsing localized strings. Underlying Foundation errors
are preserved inside ``SendableUnderlyingError`` for `.underlying` and timeout
cases, but ``NetworkError/errorCode`` always returns an InnoNetwork-owned
``NetworkErrorCode`` value rather than a Foundation `URLError.Code`. Status-code
failures keep the structured ``Response`` metadata.

A policy rejection or an authentication failure reports its own code — the
codes in the tables above — instead of the generic `4001`. A policy rejection
carries no message string; its `errorDescription` is built from the payload
and localized.

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
- ``NetworkErrorCategory``
- ``NetworkErrorSummary``
- ``NetworkPolicyRejection``
- ``NetworkAuthenticationFailure``
- ``SendableUnderlyingError``
- ``NetworkConfiguration``
- <doc:MigrationTo7>
