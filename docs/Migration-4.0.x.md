# Migration Guide: 4.0.0 → 4.0.1

The 4.0.1 hardening pass tightens behavior, durability, and concurrency
contracts across the core, download, websocket, and persistent-cache modules.
Most call sites compile unchanged; the breaking changes below cover the spots
that need source updates or behavior review.

---

## URLQueryEncoder

**NaN/Infinity now throw.** The default
`nonConformingFloatEncodingStrategy` is `.throw`, so encoding a `Double.nan`
or `.infinity` raises `EncodingError.invalidValue`. If you intentionally
shipped these values, opt back in with
`URLQueryEncoder.nonConformingFloatEncodingStrategy = .convertToString(...)`.

**Decimal locale.** `Decimal` values are now rendered through a POSIX-locked
formatter, so non-en_US locales no longer emit `,` decimal separators.

**Form encoding.** `encodeForm` is now strictly RFC 1866
`application/x-www-form-urlencoded`: spaces become `+`, `+` is percent-encoded
as `%2B`. If you were relying on the previous percent-encoded space, switch
to `encode` (URL-component encoding) or update wire-level expectations.

**Data → base64url.** `Data` values now serialize as base64url (no padding)
rather than standard base64. Servers that decoded the old format need to
support either, or callers should pre-convert.

## HTTPHeader

`HTTPHeader` storage is an ordered list. `Set-Cookie` and `WWW-Authenticate`
preserve duplicates. The `dictionary` projection has been deprecated in
favor of `URLRequest.allHTTPHeaderFields` integration; for direct dictionary
consumption, use `HTTPHeader.collapsed` (last-write-wins, only when the
caller is explicit about losing duplicates).

## MultipartFormData / MultipartResponseDecoder

- `appendFile(at:)` is now `throws` (no longer `async`). Drop the `await`
  and surface the throw to the caller. The method validates that the file
  exists at append time.
- `encode()` propagates file-read failures instead of silently dropping
  parts. Wrap call sites in `do/catch` if you previously relied on
  silent skipping.
- `MultipartResponseDecoder` raises
  `NetworkError.decoding(stage: .multipartBoundary, …)` on missing or
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

- Refresh runs as a structured child task. When every concurrent caller
  cancels, the refresh is cancelled too. If you depended on a refresh
  outliving its callers, capture the result in a separate retained `Task`.
- Consecutive failures enter an exponential cooldown
  (`baseCooldown=1s, max=30s`). Callers during cooldown receive the
  cached error. To bypass cooldown for a one-shot operator nudge, clear
  state via `await policy.reset()`.
- `Authorization` strip is case-insensitive.
- `isRefreshInProgress` is deprecated; observe coalescer state through
  the new state-machine APIs.

## CircuitBreakerPolicy

- `init` is now `throws`. Wrap construction in `try` or `try?`.
- Keys derive from `scheme://host:port`, so HTTPS and HTTP variants of
  the same host are isolated, as are explicit alt-port deployments.
- `failureThreshold` and `maxResetAfter` are validated explicitly. Bad
  values throw at init instead of being silently clamped.
- `numberOfProbesRequiredToClose` (default 1) introduces optional
  hysteresis for flapping hosts.
- DNS and TLS-pinning failures default to non-countable. Pass
  `countsTransportPreflightFailures: true` to force them back into the
  failure budget.

## DownloadConfiguration / DownloadManager

- `DownloadConfiguration.safeDefaults(...)` and `advancedTuning(...)`
  now set `allowsCellularAccess = false`. Existing apps that downloaded
  over cellular need an explicit `.cellularEnabled()` opt-in.
- The persistence base directory now defaults to a subdirectory under
  `cachesDirectory` (iCloud-backup-skipped). Apps that relied on
  `Application Support` placement should pass
  `persistenceBaseDirectoryURL` explicitly.
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
  v1 logs are accepted; new writes use schema v2 with `createdAt` and
  `lastUpdatedAt` metadata. The migration is automatic on first open;
  there is no caller action.
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
unchanged — the hook is purely additive.

## PersistentResponseCacheConfiguration

`persistenceFsyncPolicy` is a new field with three modes:

- `.always` — fd-level `fsync` of the index file and its parent
  directory after every write. Highest durability, highest IO cost.
- `.onCheckpoint` (default) — historical atomic-rename behavior.
- `.never` — rely on the OS to flush dirty pages.

Apps storing high-value responses on devices with frequent abrupt
shutdowns should opt into `.always`.

## NetworkMonitor

Lifecycle is now explicit:

```swift
let monitor = NetworkMonitor.shared
monitor.start()
// ... usage ...
monitor.stop()
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
