# RFC: One error model for 7.0

Status: accepted for 7.0.0

## Problem

Through 6.x a caller can receive two different error types for the same
failure, and one `NetworkError` case hides several unrelated failures.

1. **Two thrown types.** `NetworkClient.request(_:)` throws `NetworkError`;
   `OperationNetworkClient.start(_:).value()` throws `NetworkFailure`. The two
   disagree about recovery: `NetworkError.isRetriableHint` is `true` for
   `.underlying`, while `NetworkFailure(migratingV5:)` maps the same value to
   `.doNotRetry`.
2. **`.underlying` is a catch-all.** Failures that the library produces itself
   arrive as `.underlying` and can only be told apart by comparing an error
   domain string and a numeric code:
   - buffered response body over `ResponseBodyBufferingPolicy.maxBytes`
   - circuit breaker open
   - bounded rate-limit queue or scope registry full
   - bounded request admission queue full, or admission wait expired
   - a response that is not HTTP
   - a failed session refresh
   - a failed named request credential (`RequestSecurityFailure`)
3. **Classification is duplicated.** Retry (`ExponentialBackoffRetryPolicy`),
   circuit-breaker accounting (`CircuitBreakerRegistry`), the transport catch
   block and `NetworkFailure` each decide independently whether an error is
   transient. Because `.underlying` defaults to "transient", a response that is
   too large is retried and counted as a host failure, and a failed refresh is
   retried instead of asking the user to sign in again.

## Decision

`NetworkError` is the only type the library throws. `NetworkFailure`,
`NetworkFailureKind` and `OperationNetworkClient` are removed.

### New cases

```swift
public enum NetworkError: Error, Sendable {
    // unchanged
    case configuration(reason: NetworkConfigurationFailureReason)
    case statusCode(Response)
    case decoding(stage: DecodingStage, underlying: SendableUnderlyingError, response: Response)
    case underlying(SendableUnderlyingError, Response?)
    case reachability(ReachabilityReason, SendableUnderlyingError, Response?)
    case trustEvaluationFailed(TrustFailureReason)
    case cancelled
    case timeout(reason: TimeoutReason, underlying: SendableUnderlyingError? = nil)

    // new in 7.0
    case policyRejected(NetworkPolicyRejection)
    case authentication(NetworkAuthenticationFailure)
}
```

`policyRejected` means the library declined to send, continue or accept the
exchange because of a locally configured policy. It says nothing about the
server's health, and repeating the same request immediately gives the same
result.

```swift
public enum NetworkPolicyRejection: Sendable, Equatable {
    /// `observedBytes` is the collected size, or the declared `Content-Length`
    /// when the response was rejected before its body was read.
    case responseBodyLimitExceeded(limitBytes: Int64, observedBytes: Int64)
    case circuitOpen(CircuitBreakerOpenError)
    case rateLimitQueueFull
    case rateLimitScopeLimitReached
    case admissionQueueFull
    case admissionWaitExpired
    case nonHTTPResponse
}
```

`authentication` means the request could not be authenticated before or after
transport. A `401` that the server returns after a successful refresh stays
`.statusCode`.

```swift
public enum NetworkAuthenticationFailure: Sendable, Equatable {
    /// The session refresh operation showed that the session cannot be renewed.
    case refreshFailed(SendableUnderlyingError)
    /// A named request credential could not be selected, acquired or applied.
    case credential(RequestSecurityFailure)
}
```

After this change `.underlying` carries transport errors that the built-in
mapper did not classify, and one library-generated failure: a `304` whose
`ETag` or `Last-Modified` identifies a different representation than the
stored response the conditional request was built from, or whose merged
headers cannot be rebuilt (domain `InnoNetwork.ResponseCache`, code `304`). It
stays `.underlying` because it reports a server-side inconsistency rather than
a local decision, and it uses the case's `Response` slot to hand back the
stored response. It is transient, and truthfully so: before raising it the
executor removes the stored entry, provided that entry is still the
representation the conditional request was built from, so a replay — the
built-in retry or the caller's own — is unconditional and receives a full
response. Background stale-while-revalidate revalidation applies the same
rule. A `304` that arrives after the entry was removed or replaced by another
request removes nothing. The circuit breaker does not count the failure,
because it is raised after the `304` status was recorded as a success. No local
policy rejection or authentication failure uses `.underlying`.

`ReachabilityReason` gains `.cellularDataUnavailable` for
`URLError.dataNotAllowed`, `.internationalRoamingOff` and `.callIsActive`,
which 6.x reported as `.underlying`. One connectivity table maps `URLError`
codes to reachability reasons, and transport mapping, every
`waitsForNetworkChanges` decision and download retries read it, so a failure
cannot be a connectivity failure for one product and not for another.
`URLError.cannotConnectToHost` stays `.timeout(reason: .connectionTimeout)`.

`TimeoutReason` gains `.operationDeadline(NetworkOperationDeadlineStage)` so an
end-to-end deadline is a `NetworkError.timeout` rather than a second error
type.

### One classification

`NetworkErrorCategory` gains `.policy` and `.authentication`. A single
internal property decides transience and every consumer reads it:

| Case | Category | Transient | Counts toward the circuit breaker |
| --- | --- | --- | --- |
| `.statusCode` 5xx | `.statusCode` | yes | yes |
| `.statusCode` 408, 429 | `.statusCode` | yes | no (4xx rule below) |
| `.statusCode` other 4xx | `.statusCode` | no | no (4xx rule below) |
| `.underlying` (not cancellation) | `.transport` | yes | yes; a TLS-class error only when the policy counts transport-security failures |
| `.underlying`, domain `InnoNetwork.ResponseCache` (unreconcilable `304`) | `.transport` | yes; the replay is unconditional | no; the `304` was recorded as a success |
| `.reachability`, every reason including `.cellularDataUnavailable` | `.reachability` | yes | yes |
| `.timeout` | `.timeout` | yes | yes |
| `.trustEvaluationFailed` | `.trust` | no | only when the policy counts transport-security failures |
| `.configuration`, `.decoding`, `.cancelled` | unchanged | no | no |
| `.policyRejected` | `.policy` | no | no |
| `.authentication` | `.authentication` | no | no |

`NetworkError.isRetriableHint`, `ExponentialBackoffRetryPolicy` and
`NetworkErrorSummary.recovery` read one internal property, `isTransient`. The
circuit breaker applies the right-hand column, and the streaming handshake
uses the same retry policy and breaker.

The breaker reads the status of every completed response, not only of thrown
errors. A 5xx is a failure. A 4xx shows a working transport with a
client-side problem, so it leaves the rolling window unchanged while the
circuit is closed and counts as a successful probe while it is half-open. Any
other status is a success.

A connectivity failure is `.reachability` or an offline `.configuration`. Only
after one does `waitsForNetworkChanges` wait for a path change, and only for
one does the contextual summary recommend `.waitForConnectivity`.

### Refresh and credential failures

A failed session refresh becomes `.authentication(.refreshFailed)` only when it
shows that the session cannot be renewed:

- the refresh request was rejected with a status that is not transient, for
  example `400 invalid_grant`, `401`, `403` or `404`;
- the refresh request failed with a `URLError` that reports a rejected
  credential: `.userAuthenticationRequired`, `.userCancelledAuthentication`,
  `.clientCertificateRejected` or `.clientCertificateRequired`;
- the token response could not be decoded;
- the refresh closure threw an error of its own type.

Recovery is reauthentication, and the request is never retried. A failure that
says nothing about the session keeps its own case, because the session may
still be valid, and follows the ordinary retry and recovery rules:
cancellation, a connectivity failure, a timeout, a `408`, `429` or `5xx` from
the refresh endpoint (the `.statusCode` then carries the refresh endpoint's
response), any other `URLError` as an unclassified transport error, a
configuration failure including an offline device, a local policy rejection
such as an open circuit for the token host, and a trust failure. Only an error
that comes from a transport — a `NetworkError` or a `URLError` — can count as
transient, and a credential-rejection `URLError` never does. Any other error
type is the refresh closure's own verdict on the session.

Every refresh goes through this rule: the replay after a refreshable status
and the proactive refresh of a `.required` request that has no token yet, for
buffered requests and stream handshakes alike, so one refresh failure produces
the same error whichever path started it. Earlier drafts of 7.0 reported every
refresh failure except a connectivity failure and a timeout as
`.authentication(.refreshFailed)`, which turned a `503` from the token
endpoint into a sign-out recommendation, and classified only the replay; 6.x
surfaced the refresh error itself.

A named request credential follows the same rule. When a provider's credential
acquisition or renewal fails with a transient transport failure — a `URLError`
other than a credential rejection, or a transient `NetworkError` — the request
reports that failure's secret-free classification: `.timeout`, `.reachability`
or `.underlying` whose underlying error keeps the domain and code with the
message "Credential-protected transport failed.", or
`.configuration(reason: .offline)`. It is not reported as
`.credential(.credentialUnavailable)` or `.credential(.refreshFailed)`, and a
renewal that fails this way does not use up the request's single renewal. A
transient HTTP status from a provider still becomes `.credentialUnavailable`,
because a status would expose the provider's response. Credential preparation
— acquisition, renewal and signing — happens before anything reaches the
request's host, so the circuit breaker never counts a failure of it against
that host.

### Payload-free summary

`NetworkFailure` existed so that logs, analytics and UI state could hold a
failure without a response body, headers or URL. That value survives as a
derived, `Equatable` summary instead of a second thrown type:

```swift
public struct NetworkErrorSummary: Sendable, Equatable {
    public let category: NetworkErrorCategory
    public let code: Int
    public let statusCode: Int?
    public let recovery: NetworkRecoveryDisposition
    public let deadlineStage: NetworkOperationDeadlineStage?
}

extension NetworkError {
    public var summary: NetworkErrorSummary { get }
    public func summary(
        method: HTTPMethod,
        authentication: SessionAuthentication,
        replaySafety: NetworkOperationReplaySafety
    ) -> NetworkErrorSummary
}
```

`summary` without context never recommends replay, which is the rule
`NetworkFailure(migratingV5:)` already followed, and recommends
reauthentication only for an explicit `.authentication` failure. The
operation handle supplies the context in two places:
`NetworkOperationEvent.failed(id:summary:)` and
`NetworkOperation.failureSummary()`.

`NetworkError.errorCode` now returns the specific `NetworkErrorCode` for the
new cases (for example `4003` for a body limit) instead of the generic `4001`.

### Download

`DownloadError` follows the same rule that a terminal failure keeps its cause:

- `.maxRetriesExceeded` becomes `.maxRetriesExceeded(lastError: SendableUnderlyingError)`
- `.unacceptableStatusCode(Int)` is added for an HTTP status that another
  attempt cannot change

## Alternatives considered

- **Keep `NetworkFailure` as the single type.** It drops the response body by
  design, so an application that reads a server error payload from a 4xx
  response could not use it. `request(_:)` is also the surface that nearly all
  examples, documentation and consumer smoke tests use.
- **Struct with an open `Reason`** (the 5.0 parking-lot idea). It would make
  future additions non-breaking, but every existing `catch NetworkError.x`
  pattern would have to change. Two added cases solve the reported defects at
  a fraction of the migration cost.
- **Add only error codes.** Adding codes keeps source compatibility, but the
  retry and breaker defects come from the catch-all case itself: a default of
  "transient" for everything unclassified. Named cases let the default stay
  correct for genuine transport errors.

## Migration

See `docs/Migration-7.0.0.md`. In short:

- A `switch` over `NetworkError` without `default` needs the two new cases,
  and a `switch` over `ReachabilityReason` without `default` needs
  `.cellularDataUnavailable`.
- Code that matched `.underlying` and compared `domain`/`code` to detect a body
  limit, an open circuit, a rate-limit or admission rejection, or a credential
  failure matches `.policyRejected` or `.authentication` instead.
- `catch let failure as NetworkFailure` becomes `catch` plus `error.summary`.
