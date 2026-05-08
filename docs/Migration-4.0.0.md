# Migration Guide: 4.0.0

This guide covers the 4.0.0 hardening contract. The hardening pass tightens
behavior, durability, and concurrency contracts across the core, download,
websocket, and persistent-cache modules. Most call sites compile unchanged;
the breaking changes below cover the spots that need source updates or
behavior review.

---

## Immediate Migration Checklist

| Previous usage | 4.0.0 replacement / action |
| --- | --- |
| `Endpoint<Response>` | Use `EndpointBuilder<Response, PublicAuthScope>`. Builder roots become `EndpointBuilder<EmptyResponse, PublicAuthScope>.get(...)`, `.post(...)`, etc. |
| `AuthenticatedEndpoint<Response>` | Use `EndpointBuilder<Response, AuthRequiredScope>` and configure `NetworkConfiguration.refreshTokenPolicy`. |
| `ScopedEndpoint<Response, Scope>` / `EndpointAuthScope` | Use `EndpointBuilder<Response, Scope>` / `AuthScope`; the legacy spellings are not available in 4.0.0. |
| `WebSocketManager.shared` | Own and inject a manager per feature: `WebSocketManager(configuration:)`. |
| `DownloadManager.shared` | Use `try DownloadManager.make(configuration:)` with a unique `sessionIdentifier`; handle `DownloadManagerError` where the owning feature can recover. |
| Relying on `SendableUnderlyingError ==` comparing messages | Equality is now stable code identity only (`domain` + `code`). Compare descriptions separately if UI text matters. |
| Plain `http://` API base URLs | They fail by default. Use HTTPS, or set `allowsInsecureHTTP = true` only for a scoped local/dev client. |
| Base URLs with `user:password@host` or `#fragment` | Move credentials to `Authorization` / request interceptors and remove fragments from `baseURL`. |
| `urlSessionConfigurationOverride` with the default client initializer | Build a `URLSession` from `configuration.makeURLSessionConfiguration()` and pass it to `DefaultNetworkClient(configuration:session:)`. |
| Synchronous calls on `WebSocketManager` (e.g. `manager.connect(...)`) | Add `await`: `WebSocketManager` is now an `actor`. See "WebSocketManager actor conversion" below. |
| Exhaustive `switch` over `NetworkError` | Add an `@unknown default` arm. The 4.0.0 release adds `.transportSuspended` and `.cacheRevalidationFailed(underlying:cached:)` cases. See "NetworkError new cases" below. |
| `StreamingResumePolicy.lastEventID` paired with a bounded buffering policy | Either drop the bounded buffer or disable resume. The runtime guard now routes through `StreamingResumeStrategy.isCompatible(with:)` and emits a generic "unbounded output buffering" error message. |

## WebSocketManager actor conversion

`WebSocketManager` was a `final class` in earlier drafts of the 4.x line and is
now an `actor`. The two URLSession delegate-bridge entry points
(`handleBackgroundSessionCompletion`, the `handle*` URLSessionWebSocketDelegate
callbacks) stay `nonisolated`, so synchronous URLSession runtime callbacks
keep working without a Task hop. Every other public entry point now requires
`await` from the call site:

```swift
// 4.x earlier drafts
let task = manager.connect(url: url)
manager.disconnect(task)
manager.send(task, message: data)

// 4.0.0
let task = await manager.connect(url: url)
await manager.disconnect(task)
try await manager.send(task, message: data)
```

`WebSocketTask` was already an `actor`, so any code that `await`-ed it before
keeps compiling unchanged.

## NetworkError new cases

`NetworkError` adds two cases:
- `.transportSuspended` — `ReachabilityCheckExecutionPolicy` observed
  `.requiresConnection` for the full `suspensionWaitTimeout`, so the
  request was held back instead of dispatched into a likely failing socket.
  Distinct from `.configuration(reason: .offline(...))`, which is raised
  when the monitor reports `.unsatisfied`.
- `.cacheRevalidationFailed(underlying:, cached:)` — a 304 revalidation
  pipeline failure. The cached `Response` payload is redacted by
  `redactingFailurePayload()` unless `captureFailurePayload` is set.

`NetworkError` has been documented as non-`@frozen` since the type was
introduced; the README's error-handling section recommends ending exhaustive
switches with `@unknown default`. The 4.0.0 release exercises that contract
for the first time, so adopters that ignored the recommendation see a
"Switch must be exhaustive" warning. Add the new arms or wrap with
`@unknown default`:

```swift
catch let error as NetworkError {
    switch error {
    case .statusCode(let response):           handleStatus(response)
    case .timeout(let reason, _):             handleTimeout(reason)
    case .transportSuspended:                 handleSuspended()
    case .cacheRevalidationFailed(let underlying, let cached):
        handleRevalidationFailure(underlying, cached: cached)
    // ...
    @unknown default:
        assertionFailure("Unhandled NetworkError case — update the switch.")
    }
}
```

## NetworkConfiguration fluent modifiers

`NetworkConfiguration` gains seven `.with(...)` modifiers in 4.0.0. Existing
`NetworkConfiguration.advanced(baseURL:)` callers keep compiling; the
modifiers are an additive surface that lets adopting one new policy avoid
re-typing every other knob. The 5.0 line is expected to relocate
`customExecutionPolicies` and `eventObservers` into a protocol-bag, so new
code should prefer:

```swift
NetworkConfiguration
    .safeDefaults(baseURL: api)
    .with(retry: ExponentialBackoffRetryPolicy())
    .with(circuitBreaker: CircuitBreakerPolicy(failureThreshold: 3))
    .with(executionPolicies: [MyTracingPolicy()])
    .with(eventObservers: [MyOSLogObserver()])
```

over hand-rolling an `AdvancedBuilder` closure.

## Optional adoption

The following surfaces are new but opt-in; existing call sites keep working
without touching them:

- **`HTTPHeaderName<Variant>`** — phantom-typed header keys for
  single-value (`.authorization`, `.contentType`, etc.) versus repeatable
  (`.setCookie`, `.accept`, etc.) headers. The `String`-keyed
  `add` / `update` / subscript surface is unchanged.
- **`MultipartUploadStrategy.threshold(bytes:)`** — clamping factory for
  the `streamingThreshold` case. `MultipartAPIDefinition.uploadStrategy`
  default remains `.platformDefault`.
- **`StreamingResumeStrategy` protocol** — marker conformed by
  `StreamingResumePolicy`. Adopters who wanted to grow their own resume
  strategy now have a single extension point.
- **`PersistentResponseCacheStatistics.hitCount` / `missCount` /
  `evictionCount`** — three new in-process counters on the existing
  statistics struct. The struct's initializer keeps the original
  parameter list with default `0` values for the new fields, so call
  sites that build the struct by hand do not need to change.
- **`DownloadTask.generation` / `attempt`** — two new observation
  accessors for retry-cycle bookkeeping. The manager updates them
  internally: automatic retry and resume advance `attempt` within the
  same generation, while manual `retry(_:)` starts a new generation at
  attempt `0`.

## URLQueryEncoder

**NaN/Infinity now throw.** The default
`nonConformingFloatEncodingStrategy` is `.throw`, so encoding a `Double.nan`
or `.infinity` raises `EncodingError.unsupportedValue(reason:)`. If you
intentionally shipped these values, initialize or mutate an encoder with
`nonConformingFloatEncodingStrategy: .convertToString(...)`.

**Decimal locale.** `Decimal` values now use `Decimal.description`, which is
locale-independent, so non-en_US locales no longer emit `,` decimal separators.

**Form encoding.** `encodeForm` is now strictly RFC 1866
`application/x-www-form-urlencoded`: spaces become `+`, `+` is percent-encoded
as `%2B`. If you were relying on the previous percent-encoded space, switch
to `encode` (URL-component encoding) or update wire-level expectations.

**Data remains standard Base64.** `Data` values still serialize through
`Data.base64EncodedString()`. No server migration is required for binary
query payloads.

## HTTPHeader

`HTTPHeader` storage is an ordered list. `Set-Cookie` and `WWW-Authenticate`
preserve duplicates. `value(for:)` and the `dictionary` projection collapse
repeated case-insensitive names into a single comma-joined value while
preserving the first spelling as the canonical key. Use `values(for:)` when
the individual entries matter.

## MultipartFormData / MultipartResponseDecoder

- `appendFile(at:)` is now `throws` (no longer `async`). Drop the `await`
  and surface the throw to the caller. The method validates that the file
  exists at append time.
- `encode()` propagates file-read failures instead of silently dropping
  parts. Wrap call sites in `do/catch` if you previously relied on
  silent skipping.
- `MultipartResponseDecoder` raises
  `NetworkError.configuration(reason: .invalidRequest(...))` on missing or
  invalid boundary instead of returning an empty array.
- For non-ASCII filenames the encoder emits both `filename=` (ASCII
  fallback) and `filename*=UTF-8''<percent>` per RFC 5987. No caller
  changes required.

## RetryPolicy

`RetryPolicy.init` adds defaulted `jitterFactor` and
`maxTotalRetryDuration` parameters. Existing initializers compile
unchanged. The defaults (`jitterFactor: 0.2`,
`maxTotalRetryDuration: nil`) preserve historical behavior. `cancelled`
events now fire even when the surrounding task is cancelled — listeners
that asserted on `.cancelled` absence need to update.

## RefreshTokenPolicy

- Refresh runs in a detached single-flight task. Caller cancellation while
  awaiting the refresh no longer clears the in-flight state, so a follow-up
  caller does not launch a duplicate refresh.
- Consecutive failures enter an exponential cooldown
  (`RefreshFailureCooldown.exponentialBackoff(base: 1.0, max: 30.0)`).
  Callers during cooldown receive the cached error. Configure
  `failureCooldown: .disabled` to retain the old immediate-retry behavior.
- `Authorization` strip is case-insensitive.

## CircuitBreakerPolicy

- The existing `init(failureThreshold:windowSize:...)` remains source
  compatible and still silently clamps out-of-range values.
- New code that wants explicit validation can use the throwing
  `init(validatedFailureThreshold:windowSize:resetAfter:maxResetAfter:numberOfProbesRequiredToClose:countsTransportSecurityFailures:)`.
- Keys derive from `scheme://host:port`, so HTTPS and HTTP variants of
  the same host are isolated, as are explicit alt-port deployments.
- `failureThreshold`, `windowSize`, `resetAfter`, `maxResetAfter`, and
  `numberOfProbesRequiredToClose` are validated explicitly by the validating
  initializer.
- `numberOfProbesRequiredToClose` (default 1) introduces optional
  hysteresis for flapping hosts.
- TLS-pinning and certificate trust failures default to non-countable. Pass
  `countsTransportSecurityFailures: true` to force those security failures
  back into the failure budget. DNS/name-resolution failures remain regular
  underlying transport failures.

## DownloadConfiguration / DownloadManager

- `DownloadConfiguration.safeDefaults(...)` and `advanced(...)`
  now set `allowsCellularAccess = false`. Existing apps that downloaded
  over cellular need an explicit `.cellularEnabled()` opt-in.
- The persistence base directory remains
  `applicationSupportDirectory/InnoNetworkDownload/<sessionIdentifier>` when
  `persistenceBaseDirectoryURL` is `nil`. Apps that want iCloud-backup-skipped
  storage should pass a caches-directory URL explicitly.
- `DownloadManager.shutdown() async` is the canonical teardown:

  ```swift
  let manager = try DownloadManager.make(configuration: ...)
  // ... usage ...
  await manager.shutdown()
  ```

  After `shutdown()` the URLSession is invalidated and per-task event
  streams have ended. `deinit` retains
  `finishTasksAndInvalidate()` as a best-effort fallback for callers
  that forget to call `shutdown()`, but explicit shutdown is required
  to safely reuse the same `sessionIdentifier`.

## DownloadTaskPersistence

- The append log is replayed via `FileHandle` chunk streaming. Existing
  v1 logs are accepted and new writes keep the existing v1 record schema.
  There is no caller action.
- The directory lock now uses non-blocking `flock` with a 10s deadline.
  `withDirectoryLock` throws `CocoaError(.fileLocking)` instead of
  hanging when another process holds the lock.

## NetworkConfiguration

`urlSessionConfigurationOverride` is a new opt-in hook for proxy,
HTTP/2, connection pool, or TLS tuning:

```swift
let config = NetworkConfiguration.advanced(baseURL: url) {
    $0.urlSessionConfigurationOverride = { sessionConfig in
        sessionConfig.httpMaximumConnectionsPerHost = 8
        sessionConfig.tlsMinimumSupportedProtocolVersion = .TLSv13
        return sessionConfig
    }
}
let session = URLSession(configuration: config.makeURLSessionConfiguration())
let client = DefaultNetworkClient(configuration: config, session: session)
```

Callers that supplied their own `URLSessionConfiguration` still work
unchanged when they pass the matching `URLSession` explicitly. Constructing
`DefaultNetworkClient(configuration:)` with a non-nil override now fails fast,
because the default `URLSession.shared` cannot observe that override.

`redirectPolicy` defaults to `DefaultRedirectPolicy`. Cross-origin redirects
strip `Authorization`, `Cookie`, and `Proxy-Authorization`; same-origin
redirects keep the original request headers. Custom policies can cancel
redirects or apply stricter tenant-specific allowlists.

Plain HTTP is rejected by default during request construction. Keep production
clients on HTTPS. For local development or a controlled LAN-only endpoint,
scope the opt-in to that client:

```swift
let config = NetworkConfiguration.advanced(
    baseURL: URL(string: "http://localhost:8080")!
) {
    $0.allowsInsecureHTTP = true
}
```

## PersistentResponseCacheConfiguration

`persistenceFsyncPolicy` is a new field with three modes:

- `.always` — fd-level full sync of the index file and its parent
  directory after every write. On Darwin this uses `F_FULLFSYNC` first
  and falls back to `fsync` only when the filesystem does not support it.
  Highest durability, highest IO cost.
- `.onCheckpoint` (default) — historical atomic-rename behavior.
- `.never` — rely on the OS to flush dirty pages.

Apps storing high-value responses on devices with frequent abrupt
shutdowns should opt into `.always`.

`dataProtectionClass` is also configurable and defaults to
`.completeUnlessOpen`. The persistent cache applies it to the cache directory,
`bodies/`, body files, and `index.json` after creation. App-group consumers may
select `.completeUntilFirstUserAuthentication`; `.none` explicitly requests
`NSFileProtectionNone` for cache-owned paths when another storage layer owns
file protection.

The default privacy policy now treats credential-like key headers
(`Authorization`, `Cookie`, `Proxy-Authorization`, `X-API-Key`, `X-Auth-Token`,
and custom headers registered through `ResponseCacheHeaderPolicy`) as
authenticated. `Cache-Control: private` responses are always do-not-store.

## NetworkMonitor

Lifecycle is now explicit:

```swift
let monitor = NetworkMonitor.shared
await monitor.start()
// ... usage ...
await monitor.stop()
```

`deinit` cancels the underlying `pathUpdateHandler`. Tests that
constructed transient monitors no longer leak the handler when the
instance drops out of scope.

## Out of Scope (deferred)

- **`Response.HTTPURLResponse` value-type extraction.** Tracked as a
  v5 backlog item. The 4.0.x line keeps the existing `URLResponse?`
  surface; treat it as read-only across tasks.
- **WebSocket `permessage-deflate` real negotiation.** The underlying
  `URLSessionWebSocketTask` still does not negotiate compression. If
  `permessageDeflateEnabled` is set on the URLSession transport, 4.0.0 fails
  before opening the socket with
  `WebSocketError.unsupportedProtocolFeature(.permessageDeflate)` so the
  misconfiguration is visible. Revisit true negotiation in an optional
  transport package.
