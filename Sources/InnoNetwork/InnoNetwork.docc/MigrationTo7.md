# Migrating to InnoNetwork 7

Move a 6.x integration to one client, one configuration type, and one error
type.

7.0.0 is not published yet; 6.1.1 remains the current release, and the
installation guidance still names it. Apply this article when you move a 6.x
integration to the 7.0 line. The repository file `docs/Migration-7.0.0.md` is
the complete guide; this article covers the changes to the core module.

## Overview

7.0 removes declarations without a deprecation release. Each removed name is
still declared as `unavailable`, so the compiler names the replacement instead
of reporting an unknown identifier.

| Area | What changes | Source change needed |
| --- | --- | --- |
| Operation handles | `OperationNetworkClient` and `NetworkClientConfiguration` are removed | Yes, if you used them |
| Errors | `NetworkFailure` is removed; ``NetworkError`` gains two cases and ``ReachabilityReason`` gains one | Yes, for exhaustive switches and `NetworkFailure` users |
| Retry and circuit breaker | Local rejections and authentication failures are never retried or counted | No |
| Configuration presets | `advanced` uses the `safeDefaults` baseline; requests with credentials bypass `URLSession`'s cache | Only to keep the old values |
| Streaming | Handshakes refresh once and take part in the circuit breaker | No |
| Runtime behavior | Every change that compiles unchanged, summarized below | No; review each item |

## Operation handles live on the client

`OperationNetworkClient<Base>` wrapped a client to add `start(_:)`. Every
``NetworkClient``, ``EncodedRequestClient``, and ``UploadNetworkClient`` —
``DefaultNetworkClient``, a test stub, or your own conformer — now has `start`
directly, and ``NetworkConfiguration`` is the only configuration type.

```swift
// 6.x
let configuration = NetworkClientConfiguration.production(
    baseURL: baseURL,
    authentication: AuthPack(refreshToken: refresh)
)
let client = OperationNetworkClient<DefaultNetworkClient>(configuration: configuration)
let operation = client.start(GetUser(id: 1), deadline: .init(after: .seconds(10)))

// 7.0
let configuration = NetworkConfiguration.advanced(
    baseURL: baseURL,
    auth: AuthPack(refreshToken: refresh)
)
let client = DefaultNetworkClient(configuration: configuration)
let operation = client.start(GetUser(id: 1), deadline: .init(after: .seconds(10)))
```

| 6.x | 7.0 |
| --- | --- |
| `OperationNetworkClient(client: base).start(request)` | `base.start(request)` |
| `OperationNetworkClient<DefaultNetworkClient>(configuration:)` | `DefaultNetworkClient(configuration:)` |
| `operationClient.shutdown()` | `client.shutdown()` |
| `NetworkClientConfiguration.secure(baseURL:)` | ``NetworkConfiguration/safeDefaults(baseURL:)`` |
| `NetworkClientConfiguration.production(baseURL:resilience:authentication:…)` | ``NetworkConfiguration/advanced(baseURL:resilience:auth:observability:cache:transport:)`` |
| `NetworkClientConfiguration(migratingV5:)`, `.legacyConfiguration` | Use the ``NetworkConfiguration`` value itself |

`start` takes `replaySafety:` and `deadline:` as defaulted parameters, so the
four 6.x overloads collapse into one call shape. Uploads gain the same handle:

```swift
let upload = client.startUpload(UploadPhoto(title: title, imageData: data))
let response = try await upload.value()
```

`request(_:)` and `upload(_:)` are unchanged. Use them when you only need the
value; use `start` when you need cancellation without keeping your own
reference to the client,
lifecycle events, or an end-to-end deadline.

## One error type

### Operation values throw NetworkError

In 6.x ``NetworkOperation/value()`` threw `NetworkFailure`, a payload-free
value. It now throws the same ``NetworkError`` that `request(_:)` throws. The
payload-free value still exists as ``NetworkErrorSummary``, derived from the
error.

```swift
// 6.x
do {
    let user = try await operation.value()
} catch {                       // error: NetworkFailure
    if error.recovery == .reauthenticate { await session.signOut() }
    analytics.record(kind: error.kind.rawValue, code: error.code)
}

// 7.0
do {
    let user = try await operation.value()
} catch {                       // error: NetworkError
    let summary = await operation.failureSummary() ?? error.summary
    if summary.recovery == .reauthenticate { await session.signOut() }
    analytics.record(category: summary.category, code: summary.code)
}
```

``NetworkOperation/failureSummary()`` knows the request's method,
authentication, and replay safety, so it can recommend `.retry`,
`.waitForConnectivity`, or `.reauthenticate`. ``NetworkError/summary`` has no
request context and never recommends a replay.
``NetworkError/summary(method:authentication:replaySafety:)`` gives the
contextual form outside an operation.

| 6.x | 7.0 |
| --- | --- |
| `NetworkFailure` | ``NetworkErrorSummary`` |
| `NetworkFailure(migratingV5: error)` | `error.summary` |
| `failure.kind` (`NetworkFailureKind`) | `summary.category` (``NetworkErrorCategory``) |
| `.http` | `.statusCode` |
| `.connectivity` | `.reachability` |
| `.cancelled` | `.cancellation` |
| `.configuration`, `.transport`, `.decoding`, `.trust`, `.timeout` | Same names |
| `failure.errorDescription` | `summary.description` |
| `NetworkOperationEvent.failed(id:failure:)` | ``NetworkOperationEvent/failed(id:summary:)`` |
| `catch let failure as NetworkFailure` | `catch` (the error is ``NetworkError``) |

An expired ``NetworkOperationDeadline`` is now
`NetworkError.timeout(reason: .operationDeadline(stage), underlying: nil)`.
The stage is also available as ``NetworkErrorSummary/deadlineStage``.

Two recovery recommendations changed because 6.x computed them in two places
that disagreed:

- An unclassified transport error (`.underlying`) on a replay-safe request now
  recommends `.retry`, matching ``NetworkError/isRetriableHint``. 6.x
  recommended `.doNotRetry`.
- A named-credential failure is reported in category `.authentication`
  (6.x: `.configuration`).

### NetworkError has two new cases

```swift
case policyRejected(NetworkPolicyRejection)
case authentication(NetworkAuthenticationFailure)
```

A `switch` over ``NetworkError`` without `default` must handle both. Failures
that 6.x reported as `.underlying` with a library-owned domain and code now
arrive in these cases:

| Failure | 6.x | 7.0 |
| --- | --- | --- |
| Response over the body limit | `.underlying` (code `4003`) | `.policyRejected(.responseBodyLimitExceeded(limitBytes:observedBytes:))` |
| Circuit breaker open | `.underlying` (`CircuitBreakerOpenError` domain) | `.policyRejected(.circuitOpen(CircuitBreakerOpenError))` |
| Rate-limit queue full | `.underlying` (code `4008`) | `.policyRejected(.rateLimitQueueFull)` |
| Rate-limit scope registry full | `.underlying` (code `4009`) | `.policyRejected(.rateLimitScopeLimitReached)` |
| Admission queue full | `.underlying` (code `4006`) | `.policyRejected(.admissionQueueFull)` |
| Admission wait expired | `.underlying` (code `4007`) | `.policyRejected(.admissionWaitExpired)` |
| Non-HTTP response | `.underlying` (code `3002`) | `.policyRejected(.nonHTTPResponse)` |
| Session cannot be renewed | The refresh error, usually as `.underlying` | `.authentication(.refreshFailed(SendableUnderlyingError))` |
| Named credential failed | `.underlying` (domain `InnoNetwork.RequestSecurity`) | `.authentication(.credential(RequestSecurityFailure))` |

```swift
// 6.x
catch NetworkError.underlying(let wrapped, _)
where wrapped.domain == NetworkError.errorDomain
    && wrapped.code == NetworkErrorCode.responseBodyLimitExceeded.rawValue {
    showTooLarge()
}

// 7.0
catch NetworkError.policyRejected(.responseBodyLimitExceeded(let limit, let observed)) {
    showTooLarge(limit: limit, observed: observed)
}
```

Related changes:

- ``NetworkErrorCategory`` gains `.policy` and `.authentication`. A `switch`
  over the category without `default` must handle both.
- ``TimeoutReason`` gains ``TimeoutReason/operationDeadline(_:)``.
- ``ReachabilityReason`` gains ``ReachabilityReason/cellularDataUnavailable``.
  `URLError.dataNotAllowed`, `.internationalRoamingOff`, and `.callIsActive`,
  which 6.x reported as `.underlying`, arrive as
  `.reachability(.cellularDataUnavailable, underlying, nil)`; the underlying
  error keeps the exact code. A `switch` over ``ReachabilityReason`` without
  `default` must handle the new case.
- ``NetworkError/errorCode``, and the code of the bridged `NSError`, is now the
  specific code for these failures (`4003`, `4006`–`4009`, `3002`, and the new
  `4011` for an open circuit, `6001` for a failed refresh, `6002` for a
  credential failure). 6.x reported `4001` for all of them.
- A policy rejection carries no message string. Its `errorDescription` is
  built from the payload and localized (English and Korean).
- Only a refresh that shows the session cannot be renewed becomes
  `.authentication(.refreshFailed)`: a refresh status that is not transient
  (for example `400 invalid_grant` or `401`), a credential-rejection `URLError`
  such as `.userAuthenticationRequired`, an undecodable token response, or an
  error of the refresh closure's own type. A refresh that failed on the
  network, timed out, received a `408`, `429`, or `5xx`, failed with a
  configuration error, or was rejected by a local policy keeps its own case, as
  in 6.x, and follows the ordinary retry rules. The proactive refresh of a
  `.required` request that has no token yet follows the same rule. See
  <doc:AuthRefresh>.
- A named-credential provider whose own transport fails transiently keeps
  that failure's secret-free classification, for example
  `.reachability(.notConnectedToInternet, underlying, nil)`, instead of
  `.authentication(.credential(.credentialUnavailable))`. A renewal that fails
  this way does not use up the request's single renewal. A transient HTTP
  status from the provider still becomes `.credentialUnavailable`. A failure
  while preparing the credential is never counted against the request's host by
  the circuit breaker. See <doc:RequestCredentials>.
- `.underlying` is still used for transport errors the mapper does not
  classify, and for a `304` that cannot be reconciled with the stored response
  (domain `InnoNetwork.ResponseCache`, code `304`), which carries the stored
  response. 7.0 removes that stored entry before reporting the error, so a
  replay is unconditional and receives a full response.

See <doc:ErrorClassification> for the complete case and category tables.

## Retry and circuit-breaker classification

One rule now decides whether a failure is transient, and
``NetworkError/isRetriableHint``, ``ExponentialBackoffRetryPolicy``, the
circuit breaker, and ``NetworkErrorSummary/recovery`` all use it.

| Failure | 6.x | 7.0 |
| --- | --- | --- |
| Response over the body limit | Retried; counted against the host | Not retried; not counted |
| Open circuit, full rate-limit or admission queue | Retried | Not retried |
| Session that cannot be renewed | Retried when the refresh error arrived as `.underlying` | Not retried (`.authentication(.refreshFailed)`) |
| Refresh that failed on the network or with `408`, `429`, or `5xx` | Retried | Retried (unchanged) |
| The same refresh before the first attempt of a `.required` request, or for a stream | Not retried | Retried |
| Deterministic `URLError`: ATS block, malformed or unsupported URL, redirect loop, untrusted certificate, refused credential, local file or size limit | Retried; counted against the host (a certificate failure only when the policy counts transport-security failures) | Not retried; not counted (a certificate failure still counts when the policy counts transport-security failures) |
| Device without a network path (``ReachabilityReason/notConnectedToInternet``, ``ReachabilityReason/cellularDataUnavailable``) | Counted against every host | Not counted (still retried) |
| `waitsForNetworkChanges: true` | Waited before every retry | Waits only after a connectivity failure |

`waitsForNetworkChanges` deferred every retry until the network path changed
or `networkChangeTimeout` elapsed, including a retry after a `503` on a working
network. It now applies only after `.reachability` — including
``ReachabilityReason/cellularDataUnavailable`` — or an offline configuration
failure. Streaming handshakes and download retries use the same connectivity
table. `URLError.cannotConnectToHost` is a connection timeout, not a
connectivity failure, so a retry after it goes straight to backoff.

A custom ``RetryPolicy`` sees the new cases in
``RetryPolicy/shouldRetry(error:retryIndex:request:response:)``. If it retried
every `.underlying` error to cover these failures, add the cases it should
still retry.

## Advanced starts from safeDefaults

``NetworkConfiguration/advanced(baseURL:resilience:auth:observability:cache:transport:)``
used a second baseline that differed from
``NetworkConfiguration/safeDefaults(baseURL:)``. It now starts from
`safeDefaults`, so `advanced(baseURL:)` with no packs is identical to
`safeDefaults(baseURL:)` and adding a pack changes only what that pack states.

| Default | `advanced` in 6.x | `advanced` in 7.0 | Keep the 6.x value |
| --- | --- | --- | --- |
| Request timeout | 60 s | 30 s | `TransportPack(timeout: 60)` |
| `URLRequest.CachePolicy` | `.reloadIgnoringLocalCacheData` | `.useProtocolCachePolicy` | `TransportPack(cachePolicy: .reloadIgnoringLocalCacheData)` |
| Event buffers | 512 per partition and consumer | 256 | `ObservabilityPack(eventDeliveryPolicy: EventDeliveryPolicy(maxBufferedEventsPerPartition: 512, maxBufferedEventsPerConsumer: 512))` |

The cache-policy default depends on other packs. When ``TransportPack`` does
not set a `cachePolicy`, requests still use `.reloadIgnoringLocalCacheData` if

- ``CachePack`` sets a `responseCachePolicy` other than `.disabled`, so
  `URLSession`'s own cache does not answer for, or store beside, the library's
  response cache; or
- ``AuthPack`` configures a session refresh policy, so a response fetched with
  one session's token is not served from `URLSession`'s cache — which is keyed
  by URL, not by credential — after the session changes, even when the token
  travels in a header the library does not recognize as a credential.

`safeDefaults(baseURL:)` and `DefaultNetworkClient(baseURL:)` keep their 6.x
values. The credential rule below applies to them as well.

### Requests with credentials bypass URLSession's cache

Independently of the preset, a request that reaches transport with a
credential header — `Authorization`, `Proxy-Authorization`, `Cookie`,
`X-API-Key`, `X-Auth-Token`, or a header listed in
`CachePack(sensitiveHeaderNames:)` — never has its response stored in
`URLCache`, whatever its cache policy, and under the default
`.useProtocolCachePolicy` it is sent with `.reloadIgnoringLocalCacheData`, so
it does not read `URLCache` either. Only an explicitly cache-first policy,
`.returnCacheDataElseLoad` or `.returnCacheDataDontLoad`, opts out. The check
runs after request interceptors and token application, so it covers a
credential that your own interceptor attaches, with either preset, and it
applies to stream handshakes as well. In 6.x such a response could be served
from, and stored in, `URLCache`. The library's response cache (``CachePack``)
is not affected.

A client whose request interceptor attaches one of these headers no longer
needs `TransportPack(cachePolicy: .reloadIgnoringLocalCacheData)` for this
purpose. Set it, or list the header in `CachePack(sensitiveHeaderNames:)`,
only when a credential travels in a custom header that the library does not
recognize. See <doc:CachingStrategies>.

## Streaming handshakes use refresh and the circuit breaker

`stream(_:)` handshakes now behave like buffered requests in three ways. None
requires a source change.

- **Session refresh.** A handshake rejected with a refreshable status (`401`
  by default) is replayed once with a refreshed token, before any body byte is
  delivered. 6.x surfaced the `401`. A second rejection surfaces
  `.statusCode`. A refresh that shows the session cannot be renewed surfaces
  `.authentication(.refreshFailed)`; a refresh that failed on the network or
  with a transient status keeps its own case and follows the retry policy.
  Anonymous streams never refresh.
- **Circuit breaker.** An open circuit rejects the stream with
  `.policyRejected(.circuitOpen)` before transport, and the handshake status
  or transport failure is recorded. Bytes delivered after an accepted
  handshake are not recorded.
- **Network wait.** `waitsForNetworkChanges` follows the connectivity-only
  rule above.

Cache, request coalescing, and custom execution policies still do not apply to
streams. See <doc:StreamingGuide>.

## Other products

The optional products change in the same release. Their own documentation
catalogs describe the new behavior:

- **InnoNetworkDownload** validates the HTTP status before a file is staged
  (`DownloadTransferPack(acceptableStatusCodes:)`, default `200..<300`).
  `DownloadError.maxRetriesExceeded` becomes
  `.maxRetriesExceeded(lastError:)`, and `.unacceptableStatusCode(_:)` is
  added. An automatic retry resumes from the failed attempt's resume data, a
  transfer that followed a redirect resumes from its target instead of
  restarting from byte 0 (and restarts from the source at once if the target
  refuses),
  and `pause(_:)` issued during a retry wait takes effect. A retry waits for a
  network change only after a connectivity failure from the core module's
  table, so a retry after `URLError.cannotConnectToHost` goes straight to
  backoff.
- **InnoNetworkWebSocket** adds `WebSocketReconnectPack(stabilityInterval:)`
  (default 10 s, measured on the monotonic clock). A connection that drops
  before the interval continues the earlier reconnect budget instead of
  resetting it; `.infinity` never resets it. The `maxTotalDuration` reconnect
  window is measured on the monotonic clock as well.
- **InnoNetworkPersistentCache** verifies the byte count and SHA-256 digest of
  every stored body, adds
  `PersistentResponseCacheEvictionReason.bodyIntegrityMismatch`, and uses
  index format 5. A cache directory written by 6.x is reset on first open,
  and opening the cache drops an entry whose body file has the wrong length.

## Runtime behavior changes without compiler diagnostics

These changes compile without a source change but behave differently at run
time. The repository file `docs/Migration-7.0.0.md` keeps them as a checklist
with more detail.

| Change | Who is affected | Keep the 6.x behavior |
| --- | --- | --- |
| A body-limit, open-circuit, queue, or non-HTTP failure arrives as `.policyRejected`; a session that cannot be renewed or a credential failure arrives as `.authentication`. `.underlying` domain checks and `default` arms no longer match them, and ``NetworkError/errorCode`` is the specific code instead of `4001`. | Code, analytics, and alerts keyed on `.underlying` or `4001` | Not possible; match the new cases |
| `URLError.dataNotAllowed`, `.internationalRoamingOff`, and `.callIsActive` arrive as `.reachability(.cellularDataUnavailable, …)` instead of `.underlying`, so the network wait, `stale-if-error`, and stream resume apply to them. | Code that matched these codes inside `.underlying`; dashboards keyed on `4001` | Not possible; match the new reason |
| `advanced` uses a 30 s timeout, the protocol cache policy, and 256-event buffers. | Every client built with `advanced` | The ``TransportPack`` and ``ObservabilityPack`` values in the table above |
| A request with a credential header never stores its response in `URLSession`'s cache, and under the protocol cache policy does not read it either, with either preset. | Apps that relied on `URLCache` for authenticated requests | No exact equivalent; reuse responses through ``CachePack``, or choose a cache-first policy explicitly |
| `waitsForNetworkChanges` waits only after a connectivity failure, for requests, stream handshakes, and downloads. | Apps that relied on the wait to space out retries after server errors | Lengthen the backoff delay |
| Only a session that cannot be renewed becomes `.authentication(.refreshFailed)`, which is not retried, for the proactive refresh and the replay after a `401` alike. | Refresh closures that throw their own error type for a network problem | Rethrow the `URLError` or ``NetworkError`` |
| A credential provider's transient transport failure keeps its secret-free classification, is retried, and does not use up the request's single renewal. | ``RequestSecurity`` providers that call a backend | Throw your own error type from the provider |
| Policy rejections and authentication failures are not retried or counted by the circuit breaker. | Apps that relied on an automatic retry after them | A custom ``RetryPolicy`` for the retry |
| A deterministic `URLError` (ATS block, malformed URL, redirect loop, untrusted certificate, refused credential, local file or size limit) is not transient: not retried, recovery `.doNotRetry`, and not counted unless it is a certificate failure and the policy counts transport-security failures. A device without a network path no longer counts toward the circuit breaker. | Apps that relied on a retry after them; apps that relied on the breaker tripping while offline | A custom ``RetryPolicy`` for the retry |
| ``NetworkError/isUserVisible`` is `false` for a request credential contract the code got wrong (invalid requirements, origin mismatch, credential conflict, unsupported execution). | UI that shows every user-visible error | Not configurable; route sign-in on ``NetworkRecoveryDisposition/reauthenticate`` |
| A refresh endpoint's transient status reaches the caller without the refresh request, and a renewal stopped by a local decision about the provider's transport is not reported as `.refreshFailed`. | Code that read the refresh request from the error | Not configurable |
| Stream handshakes refresh once and take part in the circuit breaker. | Session-authenticated streams; clients with a breaker | An `.anonymous` stream; a separate client |
| An unreconcilable `304` removes the stored entry, so a replay is unconditional. | Servers with inconsistent validators | Not configurable |
| Every access to ``NetworkOperation/events`` returns its own stream that replays the lifecycle, so each consumer receives both events; consumers sharing the 6.x stream divided them. | Code that observes `events` from more than one place | Not configurable |
| An inactive VPN path reports `.vpnInactive` instead of `.unknown` on Swift 6.2 and 6.3. | Code that treats ``NetworkUnsatisfiedReason/unknown`` specially | Not configurable |

Downloads validate the HTTP status, resume a retry from resume data, and honor
`pause(_:)` during a retry wait, including after a relaunch. A WebSocket
connection must stay open for the stability interval before it resets the
reconnect budget, and `successfulReconnectCount` now counts manager reconnects
but never a first connection. The persistent cache
resets a 6.x directory on first open and verifies every body it returns.

## Removed names

Each of these fails to compile with a message naming the replacement.

| Removed | Replacement |
| --- | --- |
| `OperationNetworkClient` | `start(_:replaySafety:deadline:)` on the client |
| `NetworkClientConfiguration` | ``NetworkConfiguration`` |
| `NetworkClientConfiguration.secure(baseURL:)` | ``NetworkConfiguration/safeDefaults(baseURL:)`` |
| `NetworkClientConfiguration.production(…)` | ``NetworkConfiguration/advanced(baseURL:resilience:auth:observability:cache:transport:)`` |
| `NetworkFailure` | ``NetworkErrorSummary`` (from `error.summary`) |
| `NetworkFailureKind` | ``NetworkErrorCategory`` |

## Validation order

1. Update call sites that the compiler reports as unavailable.
2. Add the new cases to exhaustive switches over ``NetworkError``,
   ``NetworkErrorCategory``, ``TimeoutReason``, ``ReachabilityReason``,
   `DownloadError`, and `PersistentResponseCacheEvictionReason`.
3. Replace `.underlying` domain and code checks with the new cases, including
   checks for the three cellular `URLError` codes.
4. Review the three `advanced` defaults and the WebSocket stability interval
   against your server's behavior.
5. Review download endpoints that answer outside `2xx`.
6. Review each runtime behavior change in the table above.
