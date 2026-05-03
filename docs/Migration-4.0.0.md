# Migration Guide: 4.0.0

This guide covers the 4.0.0 hardening contract. The hardening pass tightens
behavior, durability, and concurrency contracts across the core, download,
websocket, and persistent-cache modules. Most call sites compile unchanged;
the breaking changes below cover the spots that need source updates or
behavior review.

---

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
  `NetworkError.invalidRequestConfiguration(...)` on missing or invalid
  boundary instead of returning an empty array.
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
- **WebSocket `permessage-deflate` real negotiation.** The configuration
  flag is wired through, but the underlying `URLSessionWebSocketTask`
  still does not negotiate compression. Use the flag as a forward-
  compatibility hint; revisit in v5.
