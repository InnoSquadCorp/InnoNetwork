# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and the project follows Semantic
Versioning.

## [4.0.1] - 2026-05-02

100-issue hardening pass distilled from a third-pass production review.
Behavior, durability, and concurrency contracts are tightened across the
core, download, websocket, and persistent-cache modules. Detailed migration
notes live in [`docs/Migration-4.0.x.md`](docs/Migration-4.0.x.md).

### Breaking

- `URLQueryEncoder`: `nonConformingFloatEncodingStrategy` defaults to
  `.throw`. NaN/Infinity now raise `EncodingError.unsupportedValue(reason:)`
  instead of serializing to provider-dependent strings. `Decimal` values use
  `Decimal.description` so non-en_US locales no longer emit `,` decimal
  separators. `Data` remains standard Base64 via `Data.base64EncodedString()`,
  and `encodeForm` produces RFC 1866 `application/x-www-form-urlencoded`
  output (space → `+`, `+` percent-encoded).
- `HTTPHeader`: storage is now an ordered list. `Set-Cookie` and
  `WWW-Authenticate` retain duplicate values; the dictionary projection
  comma-joins repeated case-insensitive names while preserving the first
  spelling as the canonical key.
- `MultipartFormData.appendFile(at:)` is now `throws` (was `async throws`)
  and validates file existence at append time. `encode()` surfaces file-read
  failures rather than silently dropping parts. RFC 5987 `filename*=UTF-8''…`
  is emitted for non-ASCII filenames; ASCII fallback is preserved.
- `MultipartResponseDecoder`: missing/invalid boundary raises
  `NetworkError.invalidRequestConfiguration(...)` instead of returning an
  empty array.
- `RetryPolicy.init`: gains `jitterFactor` and `maxTotalRetryDuration`
  parameters with safe defaults. The `cancelled` event now fires even when
  the surrounding task is cancelled.
- `RefreshTokenPolicy`: refresh completion now drives the
  idle/in-flight/cooldown state from the detached refresh task itself, so
  caller cancellation while awaiting a refresh no longer clears single-flight
  state. Consecutive failures enter
  `RefreshFailureCooldown.exponentialBackoff(base: 1.0, max: 30.0)`; callers
  during cooldown receive the cached error rather than triggering a hot-loop
  refresh. `Authorization` strip is case-insensitive.
- `CircuitBreakerPolicy.init(validatedFailureThreshold:windowSize:resetAfter:maxResetAfter:numberOfProbesRequiredToClose:countsTransportSecurityFailures:)`
  adds explicit throwing validation while the existing
  `init(failureThreshold:windowSize:...)` remains source-compatible and
  silently clamps. Keys are derived from `scheme://host:port` so different
  ports are isolated. The state machine uses a true rolling window and
  supports configurable hysteresis via `numberOfProbesRequiredToClose`.
  TLS pinning and certificate trust failures are excluded from the failure
  count by default; DNS/name-resolution failures remain regular underlying
  transport failures.
- `DownloadConfiguration.safeDefaults` and `advanced` set
  `allowsCellularAccess = false`. Use `cellularEnabled()` to opt back in.
- `DownloadManager.shutdown() async` is the canonical lifecycle teardown.
  In-flight tasks are cancelled, the URLSession is `invalidateAndCancel()`d,
  and per-task event partitions finish. `deinit` retains
  `finishTasksAndInvalidate()` as a fallback.

### Added

- `NetworkConfiguration.urlSessionConfigurationOverride` and
  `NetworkConfiguration.makeURLSessionConfiguration()` provide an escape
  hatch for proxy/HTTP2/connection-pool/TLS tuning without forking the
  abstraction.
- `PersistentResponseCacheConfiguration.persistenceFsyncPolicy` selects
  between `.always` (fd + parent-dir fsync after every index write),
  `.onCheckpoint` (default), and `.never`.
- `DownloadConfiguration.persistenceBaseDirectoryURL` lets callers move the
  append-log directory off `Application Support` (e.g., into
  `cachesDirectory`) for iCloud-backup avoidance.
- `APIDefinition` gains `timeoutOverride` and `cachePolicyOverride`
  (default `nil`) for per-request overrides.
- `MultipartFormData` includes optional `Content-Length` per-part when
  callers pass `includesPartContentLength: true`.
- Test infrastructure: `FailingFileHandle`, `FsyncFailureInjector`,
  `FlockSimulator`, `ClockFailureInjector`, and `CountingURLSession` for
  fault-injection coverage of disk, POSIX, and clock failure paths.
- `WebSocketError.reconnectWindowExceeded`: distinct terminal error when
  `reconnectMaxTotalDuration` elapses before reconnect succeeds, separate
  from `maxReconnectAttemptsExceeded` so observers can differentiate
  "network down" from "exhausted retry budget".

### Fixed

- `URLQueryEncoder`: `SnakeCaseKeyTransformCache` is bounded to 4096
  entries to prevent unbounded growth on dynamic key sets.
- `RetryCoordinator`: catch branches are deduplicated, finish ordering is
  awaited (no detached `Task` for the terminal event), and the `unknown`
  error path retains request context. Retry-After is documented as a floor.
- `ResponseCachePolicy`: query items are sorted before fingerprinting so
  semantically identical URLs hit the same cache entry. `Cookie`,
  `Proxy-Authorization`, `X-Api-Key`, and `X-Auth-Token` are sensitive by
  default. The in-memory LRU is now O(1) (doubly-linked list + dict);
  `byteCost` includes URL/method/varyHeaders/storedAt; `cachedResponseMatchesVary`
  trims OWS and treats `Accept-Encoding` as a token set.
- `WebSocketReconnectCoordinator`: any prior reconnect task is cancelled
  before a new one is registered. `URLError.cannotConnectToHost`,
  `.networkConnectionLost`, `.notConnectedToInternet`, and `.cancelled`
  are classified for ping-timeout handling. Backoff guards against
  `pow(2, -1)` and inverted random ranges. `WebSocketConfiguration`
  exposes `maximumMessageSize`, `permessageDeflateEnabled`, and
  `reconnectMaxTotalDuration`.
- `DownloadTaskPersistence`: `id(forURL:)` is O(1) via a maintained reverse
  index. The append log is replayed via `FileHandle` chunk-streaming so
  memory stays bounded on multi-MB logs. `withDirectoryLock` polls
  `flock(LOCK_EX | LOCK_NB)` with a 10s deadline and 50ms backoff instead
  of blocking indefinitely. The `fileManager` parameter is now actually
  honored. The persisted `Record` schema remains `id`/`url`/`destinationURL`/
  `resumeData`.
- `TrustPolicy`: `SecTrustEvaluateWithError` captures the underlying error
  and surfaces it via `NetworkError.trustEvaluationFailed(...)`.
- `NetworkLogger`: JWT-shaped tokens are auto-masked. CLI environments can
  inspect the same redacted payload through `os_log`.
- `EventDeliveryPolicy.default` is `.dropOldest(buffer: 256)`; unbounded
  buffering is an explicit opt-in.
- `NetworkMonitor` exposes explicit `start()`/`stop()` and cancels its
  `pathUpdateHandler` on `deinit`.
- `InFlightRegistry` cancels the underlying `URLSessionTask` when
  `cancelAll(matching:)` fires, so tag-based cancellation drops the wire
  in milliseconds.
- `URLRequest.headers` setter routes per-header through `setValue`/`addValue`
  instead of the dictionary projection so multi-value entries
  (`WWW-Authenticate`, etc.) survive round-tripping into a request.
- `PersistentResponseCache`: `lastAccessedAt` updates on the read path skip
  the durability `fsync` even under `.always` so cache-hit latency does not
  amplify into per-read disk barriers. LRU eviction is now a single sort
  + drain (was O(N²) on bulk overflow).
- `RefreshTokenCoordinator`: state transitions (idle/inFlight/cooldown) are
  driven by the detached refresh task itself rather than by the awaiter's
  catch arms, preserving single-flight even under aggressive caller
  cancellation.
- `RetryCoordinator`: cancellation event publishing is unified at a single
  chokepoint in `execute(...)` so all three catch arms produce exactly one
  `.requestFailed` event for cancelled requests.
- `MultipartFormData`: non-ASCII `name=` parts emit a paired `name*=UTF-8''…`
  RFC 5987 companion alongside the ASCII fallback (matching the existing
  `filename*` behaviour) so receivers that understand the extended syntax
  recover the original UTF-8 bytes.
- `WebSocketHeartbeatCoordinator`: every failed ping publishes
  `.error(.pingTimeout)` regardless of whether the underlying error
  matches the heartbeat classifier — silent unclassified errors no longer
  hide mid-link failures until the missed-pong threshold trips.
- `DefaultNetworkClient`: debug-only one-shot log when
  `urlSessionConfigurationOverride` is set but the client is constructed
  with `URLSession.shared`, surfacing the misconfiguration rather than
  letting the override silently no-op.
- `DownloadTaskPersistence`: `mutate(...)` acquires the directory lock via
  `Task.sleep`-based polling so a contended lock no longer pins a
  cooperative-executor thread under `usleep`.

## [4.0.0] - 2026-05-01

InnoNetwork's first public release. The package targets Apple platforms only
and is built around Swift Concurrency, explicit transport policies, and
operational visibility from prototype to production. See
[`docs/releases/4.0.0.md`](docs/releases/4.0.0.md) for the one-page release
summary.

### Added

- Internal request execution pipeline stages for built-in preflight,
  transport, post-transport, status validation, and decode handling. The
  built-in retry/cache/auth/coalescing/circuit stages remain owned by the
  executor, while `RequestExecutionPolicy` is public for custom
  transport-attempt wrappers.
- `RequestExecutionPolicy`, `RequestExecutionInput`,
  `RequestExecutionContext`, `RequestExecutionNext`, and
  `AnyRequestExecutionPolicy` for custom transport-attempt policies.
- `ResponseBodyBufferingPolicy`; inline requests now prefer
  `URLSession.bytes(for:)` with bounded collection before decoder handoff.
- `EndpointAuthScope`, `PublicAuthScope`, `AuthRequiredScope`,
  `ScopedEndpoint`, and `AuthenticatedEndpoint` for type-level auth
  boundaries. Auth-required endpoints fail before transport when no
  `RefreshTokenPolicy` is configured.
- `StateReducer` and `StateReduction` as the shared reducer vocabulary for
  lifecycle state machines.
- `InnoNetworkPersistentCache` product with `PersistentResponseCache` and
  `PersistentResponseCacheConfiguration` for conservative on-disk GET
  response caching.
- `RefreshTokenPolicy` for current-token application, single-flight refresh,
  and one-time replay after configured auth status codes.
- `RequestCoalescingPolicy` for raw transport fan-out among identical in-flight
  requests.
- `ResponseCachePolicy`, `ResponseCache`, `CachedResponse`,
  `ResponseCacheKey`, and `InMemoryResponseCache` for opt-in GET response
  caching, ETag revalidation, `304` substitution, and stale-while-revalidate.
- `CircuitBreakerPolicy` and `CircuitBreakerOpenError` for per-host failure
  budgets. Open-circuit failures use `NetworkError.underlying`; no new
  `NetworkError` enum case was added.
- `MultipartResponseDecoder` and `MultipartPart` for buffered multipart
  response parsing.
- Optional `InnoNetworkCodegen` product with `@APIDefinition` and `#endpoint`
  macros. The core runtime targets do not link `swift-syntax`; SwiftPM may
  still resolve package-level macro dependencies while loading the package
  graph.
- `APIDefinition`, `MultipartAPIDefinition`, and `StreamingAPIDefinition`
  expose `acceptableStatusCodes: Set<Int>?` for per-endpoint overrides of
  the session-wide default.
- `WebSocketCloseCode` is the public close-code type used across the WebSocket
  surface. It covers the full RFC 6455 range (1000-1015) plus library and
  application `.custom(UInt16)` codes (3000-4999), including
  `.serviceRestart` (1012) and `.tryAgainLater` (1013).
- `WebSocketEvent.ping` is emitted immediately before every heartbeat or
  public `ping(_:)` attempt, pairing with `.pong` and
  `.error(.pingTimeout)` so callers see the full attempt -> outcome
  timeline.
- `WebSocketTask.attemptedReconnectCount` and
  `successfulReconnectCount` expose per-cycle attempts and lifetime
  successes.
- `DownloadManager.make(configuration:) throws` factory mirrors the throwing
  initializer with a more discoverable name. The 4.0.0 line removes the
  global `DownloadManager.shared` singleton entirely; every feature owns
  a manager constructed via `make(configuration:)` with a unique session
  identifier and surfaces `DownloadManagerError` directly.
- `StreamingResumePolicy` (`.disabled`, `.lastEventID(maxAttempts:retryDelay:)`)
  drives optional reconnect-with-Last-Event-ID resume on streaming endpoints.
  `StreamingAPIDefinition.eventID(from:)` is the user hook that feeds the
  resume header.
- `MultipartUploadStrategy` (`.inMemory`, `.streamingThreshold(bytes:)`,
  `.alwaysStream`) selects between in-memory body assembly and streaming
  the multipart body to a temp file before upload.
  `MultipartFormData.estimatedEncodedSize` reports the projected wire size.
- `NetworkConfiguration.captureFailurePayload` (default `false`) controls
  whether `NetworkError`'s attached `Response.data` is preserved or
  redacted. `NetworkError.redactingFailurePayload()` and
  `Response.redactingData()` expose the helpers used by the executor.
- `WebSocketConfiguration.sendQueueLimit` and `sendQueueOverflowPolicy`
  (`.fail` / `.dropNewest`) bound per-task in-flight send concurrency.
  `WebSocketError.sendQueueOverflow(limit:)` and
  `WebSocketEvent.sendDropped(limit:)` surface back-pressure outcomes.
  `WebSocketTask.inFlightSendCount` reports the live counter.
- `PublicKeyPinningPolicy.HostMatchingStrategy` lets security operators choose
  host pin matching semantics. The default `.unionAllMatches` covers exact and
  parent-domain pins as a union, while `.mostSpecificHost` uses only
  the exact host's pins or the longest matching parent domain.
- DocC catalogs ship with onboarding articles for retry decisions, error
  classification, trust policies, background downloads, persistence,
  WebSocket close codes, reconnect behaviour, auth refresh,
  caching/coalescing/circuit-breaker strategy, and macro usage. The rendered
  site lives at <https://innosquadcorp.github.io/InnoNetwork/>.
- Documentation: `docs/ClientArchitecture.md`, `docs/PlatformSupport.md`,
  `docs/QueryEncoding.md`, `docs/WebSocketLifecycle.md`,
  `docs/ko/README.md` (Korean mirror of the README), and a Production
  Checklist section in the README.
- `InnoNetworkLiveTests` test target (gated behind `INNO_LIVE=1`) plus a
  daily `nightly-live` GitHub Actions workflow. Cases cover httpbin GET /
  POST / 503 and ws.postman-echo string echo.
- Parametrized `URLQueryEncoderParametrizedTests` suite locks down the
  PHP/Rails-style bracket-notation invariants, sorted-key determinism,
  rootKey enforcement, and reserved-character handling.
- `URLQueryArrayEncodingStrategy` lets `URLQueryEncoder` encode arrays as
  indexed brackets, empty brackets, or repeated keys. The default remains
  indexed brackets.
- CI `apple-platform-build-smoke` job covers macOS, iOS, tvOS, watchOS, and
  visionOS build-only smoke validation.
- Release artifacts (`benchmarks.json`, `sbom.cdx.json`) are signed with
  sigstore cosign keyless signatures. SECURITY.md describes the
  `cosign verify-blob` invocation.
- `CancellationTag` plus `NetworkClient.request(_:tag:)`,
  `NetworkClient.upload(_:tag:)`, and `DefaultNetworkClient.cancelAll(matching:)`
  for grouping requests so a screen, feature, or user session can drop
  just its own subset without draining the rest of the client. The
  tagged overloads are first-class members of the `NetworkClient`
  protocol with default implementations that forward to the
  un-tagged variant, so existing conformers (including
  `StubNetworkClient`) continue to compile while new conformers can
  honour the tag for grouped cancellation.
- `EndpointShape` base protocol that captures the HTTP envelope
  surface common to `APIDefinition` and `MultipartAPIDefinition`
  (`method`, `path`, `headers`, `logger`, `requestInterceptors`,
  `responseInterceptors`, `acceptableStatusCodes`, `transport`). Both
  endpoint protocols now inherit from `EndpointShape` and only declare
  their body-strategy surface (`parameters` / `multipartFormData` +
  `uploadStrategy`). Existing endpoints compile unchanged because the
  shared default implementations live on a single `EndpointShape`
  extension.
- Response cache honours the response `Vary` header (RFC 9111 §4.1).
  `Vary: *` responses are not stored, and concrete `Vary` headers capture a
  request-header snapshot that future lookups must match. Helpers
  `evaluateVary(responseHeaders:request:)` and
  `cachedResponseMatchesVary(_:request:)` are package-scoped utilities.
- `Examples/Auth` shows how to wire `RefreshTokenPolicy` to a
  Keychain-backed token store. The example demonstrates the closure
  contract (`currentToken`, `refreshToken`, `applyToken`), single-flight
  refresh, and replay after `401`. The library itself stays
  zero-dependency — Keychain integration lives in the example, not in
  the runtime targets.
- `DecodingInterceptor` protocol exposes a `willDecode(data:response:)`
  hook that runs after response interceptors and before the configured
  decoder, plus a generic `didDecode(_:response:)` hook that observes
  the typed value before it returns to the caller. Both methods have
  default no-op implementations so adapters only override the hook they
  actually need (envelope unwrapping, payload sanitization, decode
  metrics, typed-value normalization). `NetworkConfiguration.decodingInterceptors`
  registers them at the session level.
- All `AsyncStream` / `AsyncThrowingStream` factories owned by InnoNetwork
  now declare an explicit `bufferingPolicy`. Streaming responses,
  download delegate events, and event-hub consumer streams use
  `.unbounded` (event loss would corrupt task lifecycles or drop
  server-emitted records); `NetworkMonitor` path snapshots use
  `.bufferingNewest(16)` so a slow observer only ever sees the most
  recent network state. Behaviour is unchanged for existing callers
  whose consumers keep up with the producer.
- `WebSocketConfiguration.closeHandshakeTimeout: Duration` (default
  `.seconds(3)`) lets callers tune how long the manager waits for the
  WebSocket close handshake to finish after `cancel(with:reason:)` before
  finalizing the disconnect locally. Negative values are clamped to
  `.zero`. The previous behaviour matched the new default exactly, so
  existing code is unaffected.
- `NetworkConfiguration.responseBodyLimit: Int64?` (default `nil`)
  remains as a compatibility alias for
  `NetworkConfiguration.responseBodyBufferingPolicy.maxBytes`. When the
  configured limit is exceeded the executor short-circuits the decoder and
  throws ``NetworkError/responseTooLarge(limit:observed:)``. Cache hits,
  conditional revalidation, fresh transport responses, response
  interceptors, and decoding interceptors are checked before decoder handoff.
- ``RefreshTokenCoordinator/isRefreshInProgress`` — package-scoped
  point-in-time observation of refresh-coordinator state, used by
  ``RequestExecutor`` for refresh-aware coalescer lane segregation.
- ``RequestDedupKey`` gains an optional `refreshLane: UUID?` initializer
  parameter so the executor can synthesize per-caller dedup keys during
  refresh-in-flight windows without changing the default coalescing
  surface.
- `DownloadManager.waitForRestoration()` public restore gate.
- `DownloadError.restorationMissingSystemTask` for persisted records that no
  longer have a system URLSession task during restoration.
- Download append-log records now persist optional `resumeData`, and
  `DownloadConfiguration.PersistenceCompactionPolicy` configures compaction
  thresholds.
- `@APIDefinition` now rejects optional path-placeholder properties at macro
  expansion time.
- Benchmark JSON summary version 2 includes baseline deltas and guard
  failures. The benchmark workflow renders a PR comment and appends
  scheduled/manual results to the `benchmark-trends` branch.

### Changed

- `APIDefinition` collapses six transport-shape requirements (`contentType`,
  `requestEncoder`, `queryEncoder`, `queryRootKey`, `decoder`,
  `responseDecoder`) into a single `transport: TransportPolicy<APIResponse>`
  entry point. The default is method-aware (`GET` → `.query()`, otherwise
  `.json()`); `MultipartAPIDefinition` defaults to `.multipart()`.
  `TransportPolicy`, `RequestEncodingPolicy`, and
  `ResponseDecodingStrategy` are now public, with user-facing factories
  (`.json`, `.query`, `.formURLEncoded`, `.multipart`, `.custom`) that
  automatically pick empty-tolerant decoders for
  `HTTPEmptyResponseDecodable` outputs.
- `Endpoint` replaces `.contentType(_:)` with `.transport(_:)`. The
  `Content-Type` header is derived from the transport's request encoding,
  and `decoding(_:)` carries the request encoding into the new response
  generic instead of resetting it.
- `Endpoint<Response>` is now a compatibility alias for
  `ScopedEndpoint<Response, PublicAuthScope>`. Use
  `AuthenticatedEndpoint<Response>` or
  `ScopedEndpoint<Response, AuthRequiredScope>` for auth-required fluent
  endpoints.
- `WebSocketManager.shared` is soft-deprecated. Construct
  `WebSocketManager(configuration:)` per feature for new code.
- `DefaultNetworkClient.stream(_:)` is now a thin `AsyncThrowingStream`
  factory; the streaming pipeline (per-attempt request preparation,
  lifecycle events, response interceptors, status validation, line
  iteration, Last-Event-ID resume, request finished/failed publication)
  lives on the new `StreamingExecutor`. Observable behaviour is unchanged.
- Default request and response coders use the canonical InnoNetwork date
  format configuration, but `defaultRequestEncoder`, `defaultResponseDecoder`,
  and `defaultDateFormatter` return fresh mutable Foundation instances on each
  access so user mutation cannot leak across endpoints or concurrent requests.
- The `LowLevelNetworkClient` SPI requirements grow `tag: CancellationTag?`
  parameters; default extensions keep the old call sites
  (`perform(_:)` / `perform(executable:)`) source-compatible.
- Swift 6 language mode (`swiftLanguageMode(.v6)`) is enabled on every target.
  The package compiles under Swift 6.2+ toolchains; CI does not need an
  explicit `-strict-concurrency=complete` flag.
- `RequestExecutor` and `DefaultNetworkClient.stream(_:)` apply
  `NetworkError.redactingFailurePayload()` to errors before logging or
  surfacing them, unless the caller opts in via
  `NetworkConfiguration.captureFailurePayload`. Failure payloads attached to
  `NetworkError` are empty by default; status code, request URL, headers, and
  the `HTTPURLResponse` are preserved.
- CI: coverage tests run with `swift test --no-parallel
  --enable-code-coverage`; coverage is uploaded as an artifact and forwarded
  to Codecov when `CODECOV_TOKEN` is present. The PR benchmark smoke guard
  uses a 20% threshold, while scheduled/manual benchmark workflows use 10%.
- The release workflow generates a CycloneDX 1.5 SBOM and signs both the
  SBOM and the benchmark snapshot with sigstore cosign before attaching
  them to the GitHub Release.
- README documents the destination filename policy for
  `DownloadManager.download(url:toDirectory:fileName:)` (no rename on
  collision).
- `docs/QueryEncoding.md` formalises the `URLQueryEncoder` flattening
  rules (PHP/Rails-style bracket notation) and contrasts them with
  OpenAPI form/explode, RFC 6570, Spring, and FastAPI conventions.
- `API_STABILITY.md` now describes the evolution boundary for each
  Provisionally Stable surface, recommends `.upToNextMinor(from:)` for
  consumers who want strict compile-time stability, and explicitly lists
  `DecodingInterceptor` as provisionally stable. The README install
  snippet uses `.upToNextMinor(from:)` and links the trade-off with
  `.upToNextMajor(from:)`.
- `RequestInterceptor` and `ResponseInterceptor` now carry DocC blocks
  that document the configuration → endpoint → refresh-token application
  order, the unwinding semantics for response adapters, and the failure
  contract (interceptor throws abort the current attempt, then the
  configured retry policy decides whether another attempt runs). No
  source-level changes; existing conforming types continue to compile.
- `MultipartAPIDefinition.uploadStrategy` now defaults to
  `MultipartUploadStrategy.platformDefault`, a memory-aware
  `streamingThreshold` that picks **16 MiB** on iOS/watchOS/tvOS and
  **50 MiB** on macOS/visionOS, instead of `.inMemory`. Small payloads
  still encode in memory; bodies past the threshold spill to a temp
  file and upload via `URLSession.upload(for:fromFile:)`, bounding peak
  memory and avoiding jetsam on memory-constrained platforms.
  Endpoints that intentionally relied on the in-memory path should
  declare it explicitly with
  `var uploadStrategy: MultipartUploadStrategy { .inMemory }`; endpoints
  that need a uniform 50 MiB threshold across every platform can pin
  `.streamingThreshold(bytes: 50 * 1024 * 1024)` directly.
- `TimeoutReason.resourceTimeout` is formally produced by the internal
  transport mapper when the caller supplies `URLSessionTaskMetrics`
  and the configured resource-timeout interval. The metrics-aware
  mapping overload returns `.resourceTimeout` for `URLError.timedOut`
  only when the task interval reaches the resource budget; otherwise
  it falls back to `.requestTimeout`. Previously this case was
  reserved for higher-level transports.

### Removed

- `DownloadManager.shared` is removed in 4.0.0. The previous accessor
  trapped on first access in failure modes (duplicate session identifier,
  unavailable persistence) and forced every feature onto a single
  `DownloadConfiguration`. Construct managers via
  `DownloadManager.make(configuration:)` with a unique session identifier
  per feature; the throwing factory surfaces `DownloadManagerError`
  directly so callers can react to `duplicateSessionIdentifier` instead
  of receiving an Optional or trapping.
- `NetworkError.objectMapping(_:_:)` static factory is removed. Decode
  failures now surface exclusively as
  `NetworkError.decoding(stage:underlying:response:)` with a
  `DecodingStage` (`.responseBody`, `.streamFrame`) so retry policies
  and observability layers can distinguish where in the pipeline the
  failure happened. Migrate
  pattern matching from `.objectMapping(let underlying, let response)`
  to `.decoding(let stage, let underlying, let response)`; new
  `NetworkError.isDecodingFailure` is the canonical helper for "decode
  failures are not retried".
- `MultipartFormData.appendFile(at:name:mimeType:) throws` (the
  synchronous in-memory overload) is removed. Use the async overload
  combined with `writeEncodedData(to:)` so file bytes stream from disk
  without loading into memory at append time.
- `NetworkError.undefined` and `NetworkError.jsonMapping` — both cases were
  unreachable in production code and only existed as test fixtures.
  Decode failures now surface as `.decoding(stage:underlying:response:)`.

### Fixed

- **PersistentResponseCache overwrite (PR #39)**: `set()` on an existing key
  no longer deletes the freshly-written body file. The bodyfile cleanup runs
  only when the new entry resolves to a different filename than the existing
  one, so subsequent `get()` calls hit the new payload instead of seeing a
  cold cache. `get()`'s body-read failure handling is now separated from the
  best-effort `lastAccessedAt` index write, so a transient index write
  failure (e.g. read-only mount) no longer demotes a successful read to a
  miss.
- **PersistentResponseCache recovery scope (PR #39)**: index recovery on
  unknown version or decode failure now deletes only the cache's own
  `index.json` and `bodies/` subtree. The user-supplied configuration
  directory itself is preserved, so adjacent files in a shared parent
  directory (`sentinel.txt`, sibling caches) survive recovery.
- **RequestExecutor `responseReceived` placement (PR #39)**: the
  `NetworkEvent.responseReceived` event now fires inside the transport
  boundary used by custom `RequestExecutionPolicy` chains. A policy that
  calls `next.execute(_:)` more than once now produces one event per
  transport attempt; a policy that returns a synthetic response without
  calling `next` no longer emits a synthetic transport event.
- **Streaming `maxBytes` fallback (PR #39)**: when
  `responseBodyBufferingPolicy` is `.streaming(maxBytes:)` and the transport
  reports `invalidRequestConfiguration`, the executor no longer falls back
  to the buffered `data(for:)` path. The configured byte cap is honoured —
  the request fails fast instead of silently buffering an unbounded body.
- **Multipart auth scope (PR #39)**: `MultipartAPIDefinition` now declares
  `associatedtype Auth: EndpointAuthScope = PublicAuthScope`, so a multipart
  endpoint conforming to `AuthRequiredScope` participates in the configured
  `RefreshTokenPolicy` exactly like a non-multipart authenticated endpoint.
  Default behaviour is unchanged (`PublicAuthScope`).
- **Download resume-data clear (PR #39)**: `DownloadManager.resume(_:)` now
  surfaces persistence failures when clearing the stored `resumeData`
  before starting the new system task. On failure the in-flight task is
  cancelled and the task is surfaced as `.failed(.persistenceFailure)`,
  preventing a resumed transfer from running with stale resume bytes still
  on disk.
- **Restore-missing event delivery (PR #39)**: the
  `.failed(.restorationMissingSystemTask)` failure for orphaned persisted
  records is no longer published from `DownloadManager.init`. The event is
  flushed when the caller subscribes via `events(for:)`, so the failure is
  observable instead of being dropped into a partition with no consumer.
- **CircuitBreaker (P1.1)**: `CircuitBreakerRegistry.recordStatus(...)` no
  longer resets the rolling failure window on 4xx responses. 4xx is now a
  no-op (the transport worked, the failure is semantic), 5xx still counts
  as a transport failure, and 2xx/3xx clear the accumulated failures and
  release any half-open probe slot. Previously a single 4xx interleaved
  between 5xx/timeout failures could mask a host that was teetering on
  the failure threshold. `CircuitBreakerRegistry.recordStatus` now also
  releases the half-open probe slot when the probe response is a 4xx —
  in `.halfOpen` a 4xx closes the circuit because the probe purpose is
  to confirm the transport works, and a 4xx response satisfies that.
- **Streaming back-pressure (P1.7)**: every async stream factory now
  declares a `bufferingPolicy` explicitly. Streaming response bytes,
  download delegate events, and event-hub consumer streams use
  `.unbounded` (event loss would corrupt task lifecycles or drop
  server-emitted records); `NetworkMonitor` snapshots use
  `.bufferingNewest(16)` because only the latest path state is meaningful.
- **WebSocket close handshake timeout (P1.12)**:
  `WebSocketManager.disconnect(_:closeCode:)` now snapshots
  `configuration.closeHandshakeTimeout` into a local before spawning the
  close-handshake timer. The previous code read the timeout via
  `self?.configuration.closeHandshakeTimeout ?? .seconds(3)` *inside* the
  spawned task, so a deallocated manager would still sleep the default
  3 seconds before the no-op tail and would silently fall back to the
  default even when callers had configured a non-default value.
- **WebSocket lifecycle table (P2.8)**:
  `WebSocketState.connecting.nextStates` now lists `.reconnecting`. The
  manager already drives a connecting → reconnecting transition when a
  handshake fails and the close disposition allows reconnect, so the
  documented transition table now matches the runtime. No behavioural
  change.
- **Macro diagnostics (P1.14)**: `InnoNetworkMacros` diagnostics emitted by
  `@APIDefinition` and `#endpoint` now attach their `SourceLocation` to
  the offending syntax node (the missing argument list, the non-literal
  `path:` expression, the unlabeled `as:` argument, etc.) instead of
  falling back to a generic location on the macro attribute. IDE squiggles
  and `swift build` diagnostics now point at the exact argument the user
  has to fix. `MacroDiagnostic` exposes a new `error(at: some SyntaxProtocol)`
  helper that wraps the diagnostic in a `DiagnosticsError` anchored at the
  supplied node; `APIDefinitionMacro` and `EndpointMacro` thread the most
  precise syntax node through every throw site.
- **TimeoutReason mapping (doc + tests)**: `TimeoutReason` documentation now
  enumerates the exact `URLError` → `NetworkError.timeout(reason:)` mapping
  (`.timedOut` → `.requestTimeout`, `.cannotConnectToHost` →
  `.connectionTimeout`) and records why other transport codes (DNS failures,
  reachability errors, mid-flight drops) intentionally surface as
  `NetworkError.underlying` instead of being reclassified as timeouts.
  Lock-down tests cover `URLError.cancelled`, `.networkConnectionLost`,
  and `.notConnectedToInternet`.
- **DownloadTask state guard**: `DownloadTask.updateState(_:)` now validates
  transitions against the documented `DownloadState.canTransition(to:)` table.
  Illegal transitions trigger `assertionFailure` in DEBUG and an OSLog `.fault`
  in release, then reject the assignment so the existing state is preserved.
  State restoration (rebuilding actor state from persisted records or live
  `URLSession` task state on relaunch) and test-only state injection now
  use the new `restoreState(_:)` helper, which bypasses validation.
- **Refresh-aware coalescer lanes (P2.1)**: when a refresh is in flight,
  callers entering ``RequestExecutor`` now receive a unique coalescer
  lane suffix so a peer's pre-refresh transport result cannot leak into
  another caller's resumed continuation. Under the default coalescing
  policy (``Authorization`` participates in the dedup key) this is a
  defence-in-depth pin; under a policy that excludes ``Authorization``
  from the key it is the actual safeguard. ``RefreshTokenCoordinator``
  now exposes ``isRefreshInProgress`` (package-visible, actor-isolated)
  so the executor can read the lane state without breaking encapsulation.
- **Response cache 304-with-new-Vary preservation (P1.2)**: a 304 Not
  Modified response that carries a `Vary` header different from the one
  that was active when the cached entry was stored no longer rewrites
  the entry under the new vary dimension. The executor now refreshes the
  existing entry's `storedAt` while preserving its headers, body, and
  vary snapshot — a 304 confirms freshness of the stored representation,
  but the 304's own `Vary` describes the variant the origin would have
  served on a full 200 and must not silently rekey the stored entry.
  Behaviour is unchanged when the 304 carries the same `Vary` header
  (or no `Vary` header), so existing call sites are unaffected.

### Tests

- `ResponseCacheVaryTests` covers the new
  `notModifiedRevisesVary(cached:notModifiedHeaders:)` helper across
  same-Vary, normalized-token, different-Vary, added-Vary, and
  no-Vary-on-304 scenarios.
- `ResiliencePolicyTests.etagNotModifiedWithChangedVaryPreservesSnapshot`
  exercises the executor's 304-with-new-Vary path end-to-end.
- `DownloadTaskStateTransitionTests` (P1.10) backfills regression
  coverage for `DownloadTask.updateState`'s lifecycle guard:
  full canTransition matrix, terminal-state self-loops, every legal
  hop applies, and `restoreState` continues to bypass the guard for
  state restoration / test injection.
- `NetworkErrorTimeoutTests` (P1.11) adds a contract-lock group that
  exercises `NetworkError.mapTransportError` directly for every
  documented `URLError` code (`timedOut`, `cannotConnectToHost`,
  `cannotFindHost`, `dnsLookupFailed`, `networkConnectionLost`,
  `notConnectedToInternet`, `cancelled`) and pins the mapped
  `NetworkError` case plus the preserved underlying URLError code.
- `RefreshCoalescerRaceTests` (P2.1) covers two concurrent OLD-token
  callers entering during a held refresh, validating that both
  callers retry with the new token, that
  `RefreshTokenCoordinator.isRefreshInProgress` flips around
  `refreshAndApply`, and that `RequestDedupKey`'s `refreshLane`
  suffix distinguishes otherwise-identical keys.
- `WebSocketLifecycleReducerFuzzTests` (P3) drives the reducer with
  five deterministic SplitMix64-seeded random walks (1000 events
  each) and pins three pure-function invariants: same `(state, event,
  context)` triples produce equal transitions, generation counters
  are monotonic, and stale-generation callbacks never mutate state
  beyond emitting `.ignoreStaleCallback`. Two scripted scenarios
  cover the manual-disconnect and max-reconnect-exceeded absorbing
  terminals against every non-`reset` event.
- `IdempotencyRetryIntegrationTests` (P1.13) ties the Retry-After,
  unsafe-method idempotency, and exponential-backoff branches together
  end-to-end: POST 503 + `Retry-After` + `Idempotency-Key` retries
  once with the same key; POST 503 + `Retry-After` without
  `Idempotency-Key` does not retry; POST 503 without `Retry-After` but
  with `Idempotency-Key` falls through to exponential backoff; and an
  RFC 1123 `Retry-After` date in the past parses as `nil` so the
  policy's own delay wins.

### Documentation

- `NetworkEventHub.publish` now documents the partition lifecycle:
  observers are bound at publish time so the hub is not a replayable
  subscriber stream, and publishes that arrive after `finish(requestID:)`
  are intentionally dropped because the consumer side of the partition
  has already torn down. No behavioural change.
- `RequestCoalescingPolicy` now documents the interaction between
  coalescing and `Authorization`: the header participates in the dedup
  key by default, so callers with different tokens never share a
  transport, and `RefreshTokenPolicy` is the supported way to recover
  token-mismatch peers individually. Opting into Authorization-agnostic
  dedup remains possible but is called out as only safe when every
  caller in the cohort presents identical credentials. No behavioural
  change.
- `CachingStrategies` documents the new 304-with-new-Vary handling so
  callers know that successful conditional revalidation never rekeys
  the stored entry.
- `MigrationFromAlamofire` DocC article (P3) maps Alamofire's
  `RequestAdapter` / `RequestRetrier` / `AuthenticationInterceptor`
  onto InnoNetwork's ``RequestInterceptor`` / ``RetryPolicy`` /
  ``RefreshTokenPolicy`` split, calls out the actor-based single-flight
  refresh as the operational difference vs. Alamofire's lock-based
  serialization, and provides side-by-side 401-refresh-retry and
  per-request adapter snippets plus a four-pass migration order.
- `WebSocketProtocolPolicy` DocC article (P3) covers subprotocol
  negotiation through ``WebSocketManager/connect(url:subprotocols:)``,
  app-level protocol failure → close-code mapping, why
  `permessage-deflate` is not supported on `URLSessionWebSocketTask`,
  and heartbeat-tuning recommendations for foreground vs.
  background-eligible vs. wired deployments.
- `WebSocketBackgroundTransition` DocC article (P3) documents the
  foreground-only reconnect policy, why heartbeats should be disabled
  while suspended, and how ``WebSocketLifecycleReducer`` generations
  invalidate stale callbacks across termination.
- `ObservabilityExporters` DocC article (P3) describes how to write a
  vendor adapter (Sentry, OpenTelemetry, Pulse, Datadog) over
  ``NetworkEventObserving`` / ``NetworkEvent`` as an external package
  attached through ``NetworkConfiguration/eventObservers`` — keeping the
  core module vendor-neutral while documenting the adapter shape and
  versioning expectations.
- `OpenAPIGeneratorRecipe` DocC article (P3) walks through the
  workflow side of using `swift-openapi-generator` next to
  InnoNetwork: project layout, build-plugin output handling, thin
  ``APIDefinition`` wrappers around generated operations, drift
  guardrails, and when to graduate to the SPI integration in
  <doc:OpenAPIGeneratorAdapter>.
- `docs/rfcs/persistent-response-cache.md` (P3) RFC enumerates the six
  policies a future persistent ``ResponseCache`` companion product must
  decide before implementation: cache key composition, freshness
  precedence, eviction strategy, privacy posture for authenticated
  responses, iOS data-protection class, and on-disk format versioning.
  Code-free; positions persistent caching as a companion product
  rather than a core-module feature.
- `DecodingInterceptorCookbook` DocC article (P2.5) walks through
  ``DecodingInterceptor`` use cases: stripping a `{"data": ...}`
  envelope in `willDecode`, validating sentinel error codes in
  `didDecode`, and choosing between session-only decoding chains and
  per-endpoint placement (decoding interceptors only attach to
  ``NetworkConfiguration/decodingInterceptors``).
- `Interceptors` DocC article (P2.2) now documents the throw semantics
  shared by ``RequestInterceptor`` and ``ResponseInterceptor``: which
  later stages are skipped on throw, how errors that aren't already
  ``NetworkError`` are wrapped, and how the configured
  ``RetryPolicy`` decides whether the executor runs another attempt.
- `NetworkError.mapTransportError(_:)` now carries a full docstring
  explaining the intentionally narrow `URLError` → `.timeout` mapping
  (only `timedOut` and `cannotConnectToHost`) and why DNS/reachability
  failures stay as `.underlying`. The scattered inline rationale is
  removed in favour of one canonical place.
- Consolidated `docs/ImprovementBacklog.md` into
  `docs/reviews/4.x-comprehensive-evaluation.md`. The evaluation doc now
  carries the merged backlog as §1.5 and tracks PR-level status across
  PR #35 / #36 / #37 / #38 in §1.4. `docs/ROADMAP.md` was retargeted at
  the consolidated doc.

### Concurrency

- `DownloadManager` is a `public actor`. URL-session delegate callbacks
  enqueue into one delegate-event stream that a single consumer drains into
  the actor. `handleBackgroundSessionCompletion(_:completion:)` is
  `nonisolated` so the synchronous Foundation entry point stays usable.
- `DownloadConfiguration.persistenceFsyncPolicy: PersistenceFsyncPolicy`
  picks one of `.always`, `.onCheckpoint` (default), `.never` for the
  append-log durability barrier. The store calls `Darwin.fsync(_:)` after
  append-log mutation batches (only `.always`) and checkpoint writes (every
  policy except `.never`). See
  [`Sources/InnoNetworkDownload/InnoNetworkDownload.docc/Articles/Persistence.md`](Sources/InnoNetworkDownload/InnoNetworkDownload.docc/Articles/Persistence.md).
- No `@unchecked Sendable` usages in production sources. CI rejects any new
  `@unchecked Sendable` in shipping library targets.

### Migration

`NetworkError` is a `public` non-`@frozen` enum, so the new
`responseTooLarge(limit:observed:)` case requires consumers who write
exhaustive `switch` statements over `NetworkError` to either handle the
new case explicitly or add `@unknown default`. Code that catches
`NetworkError` without exhaustive pattern matching is unaffected. The
new case carries `errorCode == 4002` for `CustomNSError` bridging.

### Deferred

- WebSocket `permessage-deflate` extension (RFC 7692) requires a transport
  substitution because `URLSessionWebSocketTask` does not expose deflate
  negotiation. The candidate is an optional `InnoNetworkWebSocketNIO`
  product on swift-nio so the URLSession-based product stays stable.
- OpenAPI Generator integration is recipe-first. The supported path is the
  `APIDefinition` wrapper documented in DocC; generated-client SPI hooks
  remain outside the default stable contract. A separate adapter
  package/product is tracked as a roadmap candidate.
- Pulse adapter example, streaming multipart decoder, and Hummingbird
  in-process integration tests remain follow-up work.
