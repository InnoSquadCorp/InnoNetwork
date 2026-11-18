# Migration Guide: 7.0.0

This guide describes the InnoNetwork 7.0 compatibility reset. 7.0.0 is not
published yet; 6.1.1 remains the current release, and the installation
guidance in the [README](../README.md#quick-start) still names it. Apply this
guide when you move a 6.x integration to the 7.0 line.

7.0 removes declarations without a deprecation release, as 5.0 and 6.0 did.
Each removed name is still declared as `unavailable`, so the compiler names the
replacement instead of reporting an unknown identifier.

The release has one theme: one client, one configuration type, one error type.
It adds no new product and no new dependency.

| Area | What changes | Source change needed |
| --- | --- | --- |
| [Operation handles](#operation-handles-live-on-the-client) | `OperationNetworkClient` and `NetworkClientConfiguration` are removed | Yes, if you used them |
| [Errors](#one-error-type) | `NetworkFailure` is removed; `NetworkError` gains two cases and `ReachabilityReason` gains one | Yes, for exhaustive switches and `NetworkFailure` users |
| [Retry and circuit breaker](#retry-and-circuit-breaker-classification) | Local rejections and authentication failures are never retried or counted | No |
| [Configuration presets](#advanced-starts-from-safedefaults) | `advanced` uses the `safeDefaults` baseline; requests with credentials bypass `URLSession`'s cache | Only to keep the old values |
| [Streaming](#streaming-handshakes-use-refresh-and-the-circuit-breaker) | Handshakes refresh once and take part in the circuit breaker | No |
| [Download](#download) | HTTP status is validated; `DownloadError` cases change | Yes, for `DownloadError` matching |
| [WebSocket](#websocket-reconnect-budget) | A short-lived connection no longer resets the reconnect budget | Only to keep the old rule |
| [Persistent cache](#persistent-cache) | Index format 5; existing caches are reset on first open | No |
| [Runtime behavior](#runtime-behavior-changes-without-compiler-diagnostics) | Every change that compiles unchanged, as a checklist | No; review each item |

## Operation handles live on the client

`OperationNetworkClient<Base>` wrapped a client to add `start(_:)`. In 7.0
every `NetworkClient`, `EncodedRequestClient` and `UploadNetworkClient` —
`DefaultNetworkClient`, `StubNetworkClient`, and your own conformers — has
`start` directly.

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
| `NetworkClientConfiguration.secure(baseURL:)` | `NetworkConfiguration.safeDefaults(baseURL:)` |
| `NetworkClientConfiguration.production(baseURL:resilience:authentication:…)` | `NetworkConfiguration.advanced(baseURL:resilience:auth:…)` |
| `NetworkClientConfiguration(migratingV5:)`, `.legacyConfiguration` | Use the `NetworkConfiguration` value itself |

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

### `NetworkOperation.value()` throws `NetworkError`

In 6.x `value()` threw `NetworkFailure`, a payload-free value. In 7.0 it throws
the same `NetworkError` that `request(_:)` throws. The payload-free value still
exists as `NetworkErrorSummary`, derived from the error.

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

`operation.failureSummary()` knows the request's method, authentication and
replay safety, so it can recommend `.retry`, `.waitForConnectivity` or
`.reauthenticate`. `error.summary` has no request context and never recommends
a replay. `error.summary(method:authentication:replaySafety:)` gives the
contextual form outside an operation.

| 6.x | 7.0 |
| --- | --- |
| `NetworkFailure` | `NetworkErrorSummary` |
| `NetworkFailure(migratingV5: error)` | `error.summary` |
| `failure.kind` (`NetworkFailureKind`) | `summary.category` (`NetworkErrorCategory`) |
| `.http` | `.statusCode` |
| `.connectivity` | `.reachability` |
| `.cancelled` | `.cancellation` |
| `.configuration`, `.transport`, `.decoding`, `.trust`, `.timeout` | Same names |
| `failure.errorDescription` | `summary.description` |
| `NetworkOperationEvent.failed(id:failure:)` | `NetworkOperationEvent.failed(id:summary:)` |
| `catch let failure as NetworkFailure` | `catch` (the error is `NetworkError`) |

An expired `NetworkOperationDeadline` is now
`NetworkError.timeout(reason: .operationDeadline(stage), underlying: nil)`.
The stage is also available as `summary.deadlineStage`.

Two recovery recommendations changed because 6.x computed them in two places
that disagreed:

- An unclassified transport error (`.underlying`) on a replay-safe request now
  recommends `.retry`, matching `NetworkError.isRetriableHint`. 6.x recommended
  `.doNotRetry`.
- A named-credential failure is reported in category `.authentication`
  (6.x: `.configuration`).

### `NetworkError` has two new cases

```swift
case policyRejected(NetworkPolicyRejection)
case authentication(NetworkAuthenticationFailure)
```

A `switch` over `NetworkError` without `default` must handle both. Failures
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

- `NetworkErrorCategory` gains `.policy` and `.authentication`. A `switch`
  over the category without `default` must handle both.
- `TimeoutReason` gains `.operationDeadline(NetworkOperationDeadlineStage)`.
- `ReachabilityReason` gains `.cellularDataUnavailable`.
  `URLError.dataNotAllowed`, `.internationalRoamingOff` and `.callIsActive`,
  which 6.x reported as `.underlying`, arrive as
  `.reachability(.cellularDataUnavailable, underlying, nil)`; the underlying
  error keeps the exact code. A `switch` over `ReachabilityReason` without
  `default` must handle the new case.
- `NetworkErrorCode` gains `circuitOpen`, `authenticationRefreshFailed` and
  `requestCredentialFailed`. A `switch` over the code enum without `default`
  must handle them.
- `NetworkError.errorCode`, and the code of the bridged `NSError`, is now the
  specific code for these failures (`4003`, `4006`–`4009`, `3002`, and the new
  `4011` for an open circuit, `6001` for a failed refresh, `6002` for a
  credential failure). 6.x reported `4001` for all of them.
- A policy rejection carries no message string. Its `errorDescription` is
  built from the payload and localized (English and Korean).
- Only a refresh that shows the session cannot be renewed becomes
  `.authentication(.refreshFailed)`: the refresh request was rejected with a
  status that is not transient (for example `400 invalid_grant`, `401`, `403`
  or `404`) or with a credential-rejection `URLError`
  (`.userAuthenticationRequired`, `.userCancelledAuthentication`,
  `.clientCertificateRejected`, `.clientCertificateRequired`), the token
  response could not be decoded, or the refresh closure threw an error of its
  own type. A refresh that failed for a reason that says nothing about the
  session keeps its own case, as in 6.x, and follows the ordinary retry rules:
  cancellation, a connectivity failure, a timeout, a `408`, `429` or `5xx` from
  the refresh endpoint (the `.statusCode` then carries the refresh endpoint's
  response), an unclassified transport error, a configuration failure
  including an offline device, a local policy rejection such as an open circuit
  for the token host, or a trust failure. Only a `NetworkError` or a `URLError`
  thrown by the refresh closure can count as transient. The rule is the same
  for the replay after a refresh status and for the proactive refresh of a
  `.required` request that has no token yet.
- A named-credential provider whose own transport fails transiently — a
  `URLError` other than a credential rejection, or a transient `NetworkError`
  — surfaces that failure's secret-free classification, for example
  `.reachability(.notConnectedToInternet, underlying, nil)` with the message
  "Credential-protected transport failed.", instead of
  `.authentication(.credential(.credentialUnavailable))` or
  `.credential(.refreshFailed)`. An offline `.configuration` stays
  `.configuration(reason: .offline(_))`. A renewal that fails this way does not
  use up the request's single renewal, so a retry may renew again. A transient
  HTTP status from the provider still becomes `.credentialUnavailable`, because
  a status would expose the provider's response. A failure while acquiring,
  renewing or signing a named credential is never counted against the
  request's host by the circuit breaker, as in 6.x.
- `.underlying` is still used for transport errors the mapper does not
  classify, and for a `304` that cannot be reconciled with the stored response
  (domain `InnoNetwork.ResponseCache`, code `304`), which carries the stored
  response. 7.0 removes that stored entry before reporting the error, so a
  replay is unconditional and receives a full response.

## Retry and circuit-breaker classification

One rule now decides whether a failure is transient, and `isRetriableHint`,
`ExponentialBackoffRetryPolicy`, the circuit breaker and
`NetworkErrorSummary.recovery` all use it.

| Failure | 6.x | 7.0 |
| --- | --- | --- |
| Response over the body limit | Retried; counted against the host | Not retried; not counted |
| Open circuit, full rate-limit or admission queue | Retried | Not retried |
| Session that cannot be renewed | Retried when the refresh error arrived as `.underlying` | Not retried (`.authentication(.refreshFailed)`) |
| Refresh that failed on the network or with `408`, `429` or `5xx` | Retried | Retried (unchanged) |
| The same refresh before the first attempt of a `.required` request, or for a stream | Not retried | Retried |
| Deterministic `URLError`: ATS block, malformed or unsupported URL, redirect loop, untrusted certificate, refused credential, local file or size limit | Retried; counted against the host (a certificate failure only when the policy counts transport-security failures) | Not retried; not counted (a certificate failure still counts when the policy counts transport-security failures) |
| Device without a network path (`.notConnectedToInternet`, `.cellularDataUnavailable`) | Counted against every host | Not counted (still retried) |
| `waitsForNetworkChanges: true` | Waited before every retry | Waits only after a connectivity failure |

`waitsForNetworkChanges` deferred every retry until the network path changed
or `networkChangeTimeout` elapsed, including a retry after a `503` on a working
network. It now applies only after `.reachability` — including the new
`.cellularDataUnavailable` — or an offline configuration failure. Streaming
handshakes and `DownloadRetryPack`, where the option is on by default, use the
same connectivity table. `URLError.cannotConnectToHost` is a connection
timeout, not a connectivity failure, so a request or download retry after it
goes straight to backoff.

A custom `RetryPolicy` sees the new cases in `shouldRetry(error:…)`. If it
retried every `.underlying` error to cover these failures, add the cases it
should still retry.

## `advanced` starts from `safeDefaults`

`NetworkConfiguration.advanced(baseURL:…)` used a second baseline that
differed from `safeDefaults(baseURL:)`. It now starts from `safeDefaults`, so
`advanced(baseURL:)` with no packs is identical to `safeDefaults(baseURL:)`
and adding a pack changes only what that pack states.

| Default | `advanced` in 6.x | `advanced` in 7.0 | Keep the 6.x value |
| --- | --- | --- | --- |
| Request timeout | 60 s | 30 s | `TransportPack(timeout: 60)` |
| `URLRequest.CachePolicy` | `.reloadIgnoringLocalCacheData` | `.useProtocolCachePolicy` | `TransportPack(cachePolicy: .reloadIgnoringLocalCacheData)` |
| Event buffers | 512 per partition and consumer | 256 | `ObservabilityPack(eventDeliveryPolicy: EventDeliveryPolicy(maxBufferedEventsPerPartition: 512, maxBufferedEventsPerConsumer: 512))` |

The cache-policy default depends on other packs. When `TransportPack` does not
set a `cachePolicy`, requests still use `.reloadIgnoringLocalCacheData` if

- `CachePack` sets a `responseCachePolicy` other than `.disabled`, so
  `URLSession`'s own cache does not answer for, or store beside, the library's
  response cache; or
- `AuthPack` configures a session refresh policy, so a response fetched with
  one session's token is not served from `URLSession`'s cache — which is keyed
  by URL, not by credential — after the session changes, even when the token
  travels in a header the library does not recognize as a credential.

`safeDefaults(baseURL:)` and `DefaultNetworkClient(baseURL:)` keep their 6.x
values. The credential rule below applies to them as well.

### Requests with credentials bypass `URLSession`'s cache

Independently of the preset, a request that reaches transport with a
credential header — `Authorization`, `Proxy-Authorization`, `Cookie`,
`X-API-Key`, `X-Auth-Token`, or a header listed in
`CachePack(sensitiveHeaderNames:)` — never has its response stored in
`URLCache`, whatever its cache policy. Under the default
`.useProtocolCachePolicy` it is also sent with `.reloadIgnoringLocalCacheData`,
so it does not read `URLCache` either. Only an explicitly cache-first policy,
`.returnCacheDataElseLoad` or `.returnCacheDataDontLoad`, opts out of both. The
check runs after request interceptors and token application, so it covers a
credential that your own interceptor attaches, with `safeDefaults` and with
`advanced`, and it applies to stream handshakes as well. Under `advanced` with
a response cache or a session refresh policy, where the configuration's policy
is `.reloadIgnoringLocalCacheData`, credentialed responses are not stored
either. In 6.x such a response could be served from, and stored in,
`URLCache`. Signed and `RequestSecurity` requests already bypassed `URLCache`.
The library's response cache (`CachePack`) is not affected.

A client whose request interceptor attaches one of these headers no longer
needs `TransportPack(cachePolicy: .reloadIgnoringLocalCacheData)` for this
purpose. Set it, or list the header in `CachePack(sensitiveHeaderNames:)`,
only when a credential travels in a custom header that the library does not
recognize.

## Streaming handshakes use refresh and the circuit breaker

`stream(_:)` handshakes now behave like buffered requests in three ways.
None requires a source change.

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

Cache, request coalescing and custom execution policies still do not apply to
streams. A handshake that carries a credential header bypasses `URLSession`'s
cache like a buffered request.

## Download

### HTTP status is validated

A `URLSession` download task does not fail on `4xx` or `5xx`, so 6.x saved the
error body of an expired signed URL to the destination and published
`.completed`. 7.0 checks the status before the file is staged.

- `DownloadTransferPack` gains `acceptableStatusCodes` (default `200..<300`).
- `408`, `416`, `429` and `5xx` are retried under `DownloadRetryPack`.
- A resumed transfer whose range the server rejects with `416`, or whose
  redirect target refuses it, restarts from the source URL at once without
  spending the retry budget.
- Any other unacceptable status fails immediately with
  `DownloadError.unacceptableStatusCode(_:)`. Nothing is written to the
  destination.

If your server answers a download with a status outside `2xx` on purpose,
widen the set:

```swift
let configuration = DownloadConfiguration.advanced(
    sessionIdentifier: "com.example.app.media",
    transfer: DownloadTransferPack(acceptableStatusCodes: Set(200..<300).union([304]))
)
```

### `DownloadError` changes

```swift
// 6.x
case maxRetriesExceeded

// 7.0
case maxRetriesExceeded(lastError: SendableUnderlyingError)
case unacceptableStatusCode(Int)
```

```swift
// 6.x
if case .failed(.maxRetriesExceeded) = event { showRetryLater() }

// 7.0
if case .failed(.maxRetriesExceeded(let lastError)) = event {
    showRetryLater(reason: lastError.message)
}
```

`DownloadError.httpStatusCode` returns the status for
`.unacceptableStatusCode` and for a `.maxRetriesExceeded` whose final attempt
ended on a status.

### Behavior changes without source changes

- **Automatic retry resumes.** A retry continues from the resume data of the
  failed attempt instead of restarting from byte 0, and falls back to a fresh
  request when the server rejects the range.
- **Redirected transfers resume.** `resume(_:)` and an automatic retry
  continue a transfer that followed a redirect from the redirect target that
  Foundation restores, when the download redirect policy would admit that
  target unchanged. 6.x restarted every redirected transfer from byte 0. A
  target the policy would refuse, such as an HTTPS-to-HTTP downgrade, still
  restarts from the source URL. When the target refuses the resumed request
  with a status other than `408`, `429` or `5xx`, as an expired signed URL
  does, the task does not fail: it restarts from the source at once, which
  redirects afresh. Like the restart after a rejected range, it waits for no
  backoff and spends no retry, so it works with retries disabled.
- **`pause(_:)` during a retry wait takes effect.** 6.x dropped a pause issued
  while a retry was waiting for backoff or a network change, and the task
  restarted. The task now ends `.paused` and keeps the resume data of the
  attempt that failed last.
- **Network wait.** `DownloadRetryPack(waitsForNetworkChanges:)` (default
  `true`) now waits only after a connectivity failure, read from the core
  module's table: `notConnectedToInternet`, `dnsLookupFailed`,
  `cannotFindHost`, `networkConnectionLost`, `dataNotAllowed`,
  `internationalRoamingOff` and `callIsActive`. A retry after
  `cannotConnectToHost`, a retryable status or a timeout goes straight to
  backoff.
- **Persistence.** A mutation replays the append log only when another writer
  changed it. See
  [the append-log RFC](rfcs/download-append-log-compaction.md#mutation-fast-path-70).

## WebSocket reconnect budget

6.x cleared `maxAttempts` and `maxTotalDuration` whenever a connection opened,
so a server that accepted every connection and closed it at once was retried
forever. `WebSocketReconnectPack` gains `stabilityInterval` (default 10 s): a
connection that drops before the interval continues the earlier budget.

```swift
// Keep the 6.x rule: every opened connection resets the budget.
let configuration = WebSocketConfiguration.advanced(
    reconnect: WebSocketReconnectPack(stabilityInterval: 0)
)
```

`safeDefaults()` takes no packs, so the snippet starts from the `advanced`
tuning — a 15 s heartbeat, 8 attempts, 512 buffered events and more. Pass the
other packs too if your app relies on a `safeDefaults` value. A
`stabilityInterval` of `.infinity` never resets the budget, so `maxAttempts`
caps the task's whole lifetime; a negative value is `0`, and NaN the
standard 10 s. The interval is measured on the monotonic clock, and so is
the `maxTotalDuration` reconnect window, which 6.x measured on the wall clock;
a wall-clock correction changes neither.

`WebSocketTask.attemptedReconnectCount` still reads `0` while a connection is
open. If that connection drops before the interval, the earlier count is
restored and keeps growing.

`WebSocketTask.successfulReconnectCount` now increments when the manager
reconnects. In 6.x it stayed at `0`, so a dashboard built on it starts
reporting real values. Only a connection after an earlier one counts: a first
connection whose handshake had to be retried does not.

## Persistent cache

- Every entry records the byte count and SHA-256 digest of its body, and
  `get(_:)` verifies both. A mismatch is a miss that scrubs the entry with
  the new `PersistentResponseCacheEvictionReason.bodyIntegrityMismatch`. A
  `switch` over that enum without `default` must handle the new case.
- Opening the cache already drops an entry whose body file is not the
  recorded length, reported with the same reason, and removes a body staging
  file a crash left behind once it is more than an hour old.
- The index format is version 5. A cache directory written by 6.x is reset on
  first open: the index and bodies are removed and the cache starts empty. The
  key file and unrelated files are kept.

## Runtime behavior changes without compiler diagnostics

The changes below compile without a source change but behave differently at
run time. Check each one against your application. "Keep 6.x" names the
setting that restores the old behavior, where one exists.

- [ ] **Errors that left `.underlying`.** A response over the body limit, an
  open circuit, a full rate-limit or admission queue and a non-HTTP response
  arrive as `.policyRejected`; a session that cannot be renewed and a
  named-credential failure arrive as `.authentication`. A
  `catch NetworkError.underlying(…) where` check on domain and code, or a
  `switch` with `default`, still compiles but no longer matches them.
  `errorCode` reports `4003`, `4006`–`4009`, `4011`, `3002`, `6001` or `6002`
  instead of `4001`, and the observability category is `policy.*` or
  `authentication.*` instead of `transport.*`. *Affected:* code, analytics and
  alerts keyed on `.underlying`, `4001` or `transport.*`. *Keep 6.x:* not
  possible; match [the new cases](#networkerror-has-two-new-cases).
- [ ] **Cellular data failures are reachability failures.**
  `URLError.dataNotAllowed`, `.internationalRoamingOff` and `.callIsActive`
  arrive as `.reachability(.cellularDataUnavailable, underlying, nil)` instead
  of `.underlying`: category `.reachability`, code `4002` instead of `4001`,
  observability category `reachability.cellular_data_unavailable`, and, for a
  request that may be replayed, a contextual recovery of
  `.waitForConnectivity`. `waitsForNetworkChanges` now
  waits for a path change after them, `stale-if-error` can answer them from a
  stored response, and `StreamingResumePolicy` reconnects after them.
  *Affected:* code that matched these codes inside `.underlying`; dashboards
  keyed on the code or category. *Keep 6.x:* not possible; match
  `.reachability(.cellularDataUnavailable, let underlying, _)` and read
  `underlying.code` for the exact code.
- [ ] **`advanced` defaults.** Without packs, `advanced(baseURL:)` equals
  `safeDefaults(baseURL:)`: a 30 s request timeout instead of 60 s,
  `.useProtocolCachePolicy` instead of `.reloadIgnoringLocalCacheData` unless a
  response cache or a session refresh policy is configured, and 256 buffered
  events per partition and consumer instead of 512. *Affected:* every client
  built with `advanced`. *Keep 6.x:* pass the 6.x values through
  `TransportPack` and `ObservabilityPack`, as listed in
  [the table](#advanced-starts-from-safedefaults).
- [ ] **Requests with credentials bypass `URLSession`'s cache.** A request or
  stream handshake that reaches transport with `Authorization`,
  `Proxy-Authorization`, `Cookie`, `X-API-Key`, `X-Auth-Token` or a header in
  `CachePack(sensitiveHeaderNames:)` never has its response stored in
  `URLCache`, whatever its cache policy, and under the default
  `.useProtocolCachePolicy` it is sent with `.reloadIgnoringLocalCacheData`, so
  it does not read `URLCache` either. This holds with either preset, including
  `advanced` with a response cache or a refresh policy. Only an explicitly
  cache-first policy (`.returnCacheDataElseLoad`, `.returnCacheDataDontLoad`)
  opts out. *Affected:* apps that relied on `URLCache` to answer or revalidate
  authenticated requests, for example under `safeDefaults`. *Keep 6.x:* no
  exact equivalent; to reuse authenticated responses, use the library's
  response cache (`CachePack`), which partitions entries by a credential
  fingerprint, or choose a cache-first policy for the request explicitly.
- [ ] **Network wait only after connectivity failures.** With
  `waitsForNetworkChanges: true`, 6.x waited for a path change, up to
  `networkChangeTimeout`, before every retry. 7.0 waits only after
  `.reachability`, including `.cellularDataUnavailable`, or an offline
  `.configuration`, for buffered requests, stream handshakes and downloads
  (`DownloadRetryPack`, on by default). A retry after a `503`, a timeout or
  `URLError.cannotConnectToHost` goes straight to backoff. *Affected:* apps
  that relied on the wait to space out retries after server errors or
  timeouts. *Keep 6.x:* not configurable; lengthen the backoff with
  `ExponentialBackoffRetryPolicy(retryDelay:maxDelay:)` or
  `DownloadRetryPack(retryDelay:maxRetryDelay:)`.
- [ ] **Session refresh failures.** A refresh that shows the session cannot be
  renewed — a non-transient refresh status such as `400 invalid_grant` or
  `401`, a credential-rejection `URLError` such as
  `.userAuthenticationRequired`, an undecodable token response, or an error of
  the refresh closure's own type — becomes `.authentication(.refreshFailed)`.
  It is not retried, the breaker does not count it, and the contextual
  recovery is `.reauthenticate`. The rule covers the replay after a `401` and
  the proactive refresh of a `.required` request that has no token yet. 6.x
  surfaced the refresh error itself, and retried it when it arrived as
  `.underlying` — including `URLError(.userAuthenticationRequired)`. A refresh
  that failed on the network, with a `408`, `429` or `5xx`, or with a
  configuration error keeps its own case, as in 6.x; a `.statusCode` then
  carries the refresh endpoint's response. *Affected:* refresh closures that
  throw their own error type for a network problem, or a credential-rejection
  `URLError` for a server outage; such an error now asks for sign-in instead
  of a retry. *Keep 6.x:* rethrow the `URLError` or `NetworkError` from the
  closure for failures that should stay retryable, and report an outage of
  the token service with a transient error such as
  `URLError(.badServerResponse)`, as `Examples/Auth` does. A transient
  refresh failure is retried on every path, including the proactive refresh
  and streams, and its `.statusCode` carries the refresh endpoint's response
  without the refresh request, whose body or headers hold the refresh token.
- [ ] **Named-credential provider failures.** A provider whose own transport
  fails transiently (a `URLError` other than a credential rejection, or a
  transient `NetworkError`) produces that failure's secret-free
  classification, such as `.reachability(.notConnectedToInternet, …)` with the
  message "Credential-protected transport failed." It is retried under the
  ordinary rules, a renewal that fails this way does not use up the request's
  single renewal, and the circuit breaker does not count it against the
  request's host. 6.x reported every provider failure as
  `.credentialUnavailable` or `.refreshFailed`, which was never retried. A
  transient HTTP status from the provider still becomes
  `.credentialUnavailable`. A renewal stopped by a local policy rejection, a
  trust failure or a configuration failure of the provider's transport keeps
  that classification as well, instead of `.refreshFailed`. *Affected:*
  `RequestSecurity` providers that call a backend. *Keep 6.x:* throw your own error type from the provider; it
  becomes `.credentialUnavailable`, or `.refreshFailed` for a renewal, and is
  not retried.
- [ ] **Local rejections and authentication failures are not retried or
  counted.** In 6.x a response over the body limit was retried and counted
  against the host, and an open circuit or a full rate-limit or admission
  queue was retried. The built-in policy now retries none of them, and the
  breaker counts no policy rejection or authentication failure. *Affected:*
  apps that relied on an automatic retry after these failures. *Keep 6.x:* a
  custom `RetryPolicy` can return `.retry` for `.policyRejected`; breaker
  counting cannot be restored.
- [ ] **Deterministic transport failures are not retried or counted.** An
  `.underlying` failure whose `URLError` cannot change on a replay — App
  Transport Security blocked the request, a malformed or unsupported URL, a
  redirect loop or a redirect to nowhere, a server certificate the system
  does not trust, a refused client certificate or credential, or a local file
  or size limit — is no longer transient: `isRetriableHint` is `false`, the
  built-in policy does not retry it, the summary recommends `.doNotRetry`, and
  the breaker does not count it. A certificate failure is the exception for the
  breaker: as in 6.x, it counts when `countsTransportSecurityFailures` is
  `true`. *Affected:* apps that relied on an automatic retry after these.
  *Keep 6.x:* a custom `RetryPolicy` can return `.retry` for them.
- [ ] **An offline device does not open circuits.** A
  `.reachability(.notConnectedToInternet)` or `.cellularDataUnavailable`
  failure is still retried but no longer counts toward the host's circuit
  breaker, so circuits are not open when the device reconnects. *Affected:*
  apps that relied on the breaker tripping while offline. *Keep 6.x:* not
  configurable.
- [ ] **Credential setup mistakes are not user-visible.** `isUserVisible` is
  `false` for `.authentication(.credential(_:))` with `.invalidRequirements`,
  `.originMismatch`, `.credentialConflict` or `.unsupportedExecution`: the
  user cannot act on them. Route sign-in on `summary.recovery ==
  .reauthenticate` rather than on the `.authentication` category.
  *Affected:* UI that shows every user-visible error. *Keep 6.x:* not
  configurable.
- [ ] **Stream handshakes refresh and use the circuit breaker.** A
  session-authenticated stream whose handshake is rejected with `401` is
  replayed once with a refreshed token instead of surfacing the `401`. With a
  `CircuitBreakerPolicy`, an open circuit rejects the stream with
  `.policyRejected(.circuitOpen)` before transport, and a handshake `5xx` or
  transport failure counts toward the host. *Affected:* streaming endpoints
  with `.optional` or `.required` session authentication, and clients that
  combine streams with a circuit breaker. *Keep 6.x:* declare the stream
  `.anonymous` and attach its token in a request interceptor; use a separate
  client without a breaker for streams.
- [ ] **Downloads validate the HTTP status.** A `4xx` or `5xx` response no
  longer completes the download. Nothing is written to the destination; `408`,
  `416`, `429` and `5xx` are retried, and other statuses fail with
  `.unacceptableStatusCode(_:)`. 6.x saved the error body and published
  `.completed`. The `206` that answers a resumed attempt's range request is
  accepted even when the configured set omits it. *Affected:* servers that
  answer a download outside `2xx` on purpose. *Keep 6.x:* widen
  `DownloadTransferPack(acceptableStatusCodes:)`.
- [ ] **Download retries resume, and `pause(_:)` works during a retry wait.**
  An automatic retry continues from the failed attempt's resume data and
  restarts from the source URL at once, without spending a retry, after a
  `416`. A `pause(_:)` issued while a retry
  waits now pauses the task, which keeps the resume data of the attempt that
  failed last, including a retry restored after a relaunch and a pause that
  races the failure itself; 6.x dropped the pause and restarted the transfer.
  A transfer that followed a redirect resumes from its target when the
  download redirect policy would admit it unchanged, and restarts from the
  source at once if the target refuses; 6.x restarted it from byte 0.
  *Affected:* downloads from servers that answer range requests incorrectly;
  apps that pause during a retry wait. *Keep 6.x:* not configurable.
- [ ] **WebSocket reconnect budget.** A connection must stay open for
  `stabilityInterval` (default 10 s) before it resets `maxAttempts` and
  `maxTotalDuration`; one that drops sooner continues the earlier budget, so a
  server that accepts and closes every connection exhausts `maxAttempts`.
  `successfulReconnectCount` now increments when the manager reconnects; it
  stayed at `0` in 6.x, and a first connection never counts. *Affected:* connections that normally last less than
  10 s; dashboards built on the counters. *Keep 6.x:*
  `WebSocketReconnectPack(stabilityInterval: 0)` for the budget; the counter
  has no switch.
- [ ] **Persistent cache format 5.** A cache directory written by 6.x is reset
  on first open, so the first launch after the upgrade starts with an empty
  cache. Every `get(_:)` verifies the body's byte count and SHA-256 digest; a
  mismatch is a miss that scrubs the entry with `.bodyIntegrityMismatch`, and
  opening the cache scrubs an entry whose body file has the wrong length.
  *Affected:* apps that read cached responses offline right after upgrading.
  *Keep 6.x:* not possible; a 6.x index has no digests to verify.
- [ ] **An unreconcilable `304` removes the stored entry.** When a `304`'s
  `ETag` or `Last-Modified` identifies a different representation than the
  stored response the conditional request was built from, or the merged
  headers cannot be rebuilt, the entry is removed, if it is still that
  representation, before the same `.underlying` error (domain
  `InnoNetwork.ResponseCache`, code `304`) is reported. A retry, built-in or
  your own, is then unconditional and receives a full response; in 6.x it sent
  the same conditional request and received the same `304`. Background
  stale-while-revalidate refreshes follow the same rule. *Affected:* servers
  with inconsistent validators, which now serve one full response. *Keep 6.x:*
  not configurable.
- [ ] **Each `events` access is its own stream.** `NetworkOperation.events`
  returns a new stream on every access that replays the lifecycle so far, so
  every consumer receives `.started` and the terminal event. In 6.x each
  access returned the same stream, and consumers iterating it at the same time
  divided the two events between them. *Affected:* code that observes
  `events` from more than one place. *Keep 6.x:* not configurable.
- [ ] **Inactive VPN path on Swift 6.2 and 6.3.** Built with those toolchains,
  `NetworkSnapshot` reports `NetworkUnsatisfiedReason.vpnInactive` instead of
  `.unknown`. *Affected:* code that treats `.unknown` specially. *Keep 6.x:*
  not configurable.

## A complete 7.0 call site

The fragments above show one change at a time. The block below combines the
7.0 entry points in one place and is compiled against the package in CI, so it
cannot drift from the API.

<!-- compile-check -->
```swift
import Foundation
import InnoNetwork

struct Profile: Decodable, Sendable {
    let name: String
}

struct GetProfile: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Profile

    var method: HTTPMethod { .get }
    var path: String { "/me" }
    var sessionAuthentication: SessionAuthentication { .required }
}

enum ProfileOutcome {
    case loaded(Profile)
    case signInAgain
    case tooLarge(limitBytes: Int64, observedBytes: Int64)
    case failed(NetworkErrorSummary)
}

func makeProfileClient(refresh: RefreshTokenPolicy) -> DefaultNetworkClient {
    DefaultNetworkClient(
        configuration: .advanced(
            baseURL: URL(string: "https://api.example.com")!,
            auth: AuthPack(refreshToken: refresh)
        )
    )
}

func loadProfile(with client: DefaultNetworkClient) async -> ProfileOutcome {
    let operation = client.start(
        GetProfile(),
        deadline: NetworkOperationDeadline(after: .seconds(10))
    )
    do throws(NetworkError) {
        return .loaded(try await operation.value())
    } catch .policyRejected(.responseBodyLimitExceeded(let limitBytes, let observedBytes)) {
        return .tooLarge(limitBytes: limitBytes, observedBytes: observedBytes)
    } catch .authentication(.refreshFailed) {
        return .signInAgain
    } catch {
        // The operation's summary knows the method and authentication, so
        // its recovery can recommend a retry or reauthentication.
        let summary = await operation.failureSummary() ?? error.summary
        return summary.recovery == .reauthenticate ? .signInAgain : .failed(summary)
    }
}
```

## Removed names

Each of these fails to compile with a message naming the replacement.

| Removed | Replacement |
| --- | --- |
| `OperationNetworkClient` | `start(_:replaySafety:deadline:)` on the client |
| `NetworkClientConfiguration` | `NetworkConfiguration` |
| `NetworkClientConfiguration.secure(baseURL:)` | `NetworkConfiguration.safeDefaults(baseURL:)` |
| `NetworkClientConfiguration.production(…)` | `NetworkConfiguration.advanced(…)` |
| `NetworkFailure` | `NetworkErrorSummary` (from `error.summary`) |
| `NetworkFailureKind` | `NetworkErrorCategory` |

## What the API diff reports

`swift package diagnose-api-breaking-changes 6.1.1` lists every change in this
guide. It also lists two entries that need no source change:
`DownloadTransferPack.init` and `WebSocketReconnectPack.init` are reported as
removed because each gained a defaulted parameter (`acceptableStatusCodes:`
and `stabilityInterval:`); existing call sites compile unchanged. The
remaining entries it prints are `package` declarations that applications
cannot reach.

The complete list is recorded in `Scripts/api-breaks/7.0.0-public.allowlist`
(consumer-visible, each named in this guide) and
`Scripts/api-breaks/7.0.0-package.allowlist`. `Scripts/check_api_breaking_changes.sh`
runs the comparison and fails on any breaking change that is not listed there.

## Validation order

1. Update call sites that the compiler reports as unavailable.
2. Add the new cases to exhaustive switches over `NetworkError`,
   `NetworkErrorCategory`, `TimeoutReason`, `ReachabilityReason`,
   `DownloadError` and `PersistentResponseCacheEvictionReason`.
3. Replace `.underlying` domain and code checks with the new cases, including
   checks for the three cellular `URLError` codes.
4. Review the three `advanced` defaults and the WebSocket stability interval
   against your server's behavior.
5. Review download endpoints that answer outside `2xx`.
6. Work through the
   [runtime behavior checklist](#runtime-behavior-changes-without-compiler-diagnostics).
