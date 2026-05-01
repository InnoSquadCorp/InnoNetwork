# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and the project follows Semantic
Versioning for the 4.x release line.

## [Unreleased]

### Added

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
  enforces a soft upper bound on the size of buffered response bodies.
  When the configured limit is exceeded the executor short-circuits the
  decoder and throws ``NetworkError/responseTooLarge(limit:observed:)``.
  Cache hits, conditional revalidation, and fresh transport responses are
  checked before cache writes, and the final decoder input is rechecked
  after response and decoding interceptors. The guard is opt-in; setting
  it to `nil` keeps the prior unbounded behaviour. Endpoints that need
  genuine memory-bounded handling should use the streaming surface
  (`stream(_:)` / `bytes(for:)`).

### Fixed

- `WebSocketState.connecting.nextStates` now lists `.reconnecting`. The
  manager already drives a connecting → reconnecting transition when a
  handshake fails and the close disposition allows reconnect, so the
  documented transition table now matches the runtime. No behavioural
  change.

### Changed

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
  `.streamingThreshold(bytes: 50 * 1024 * 1024)` (50 MiB) instead of
  `.inMemory`. Small payloads still encode in memory; bodies past the
  threshold spill to a temp file and upload via `URLSession.upload(for:fromFile:)`,
  bounding peak memory by default. Endpoints that intentionally relied on
  the in-memory path should now declare it explicitly:
  `var uploadStrategy: MultipartUploadStrategy { .inMemory }`.

#### Migration: `NetworkError.responseTooLarge`

`NetworkError` is a `public` non-`@frozen` enum, so the new
`responseTooLarge(limit:observed:)` case requires consumers who write
exhaustive `switch` statements over `NetworkError` to either handle the
new case explicitly or add `@unknown default`. Code that catches
`NetworkError` without exhaustive pattern matching is unaffected. The
new case carries `errorCode == 4002` for `CustomNSError` bridging.

### Deprecated

- `DownloadManager.shared` is now soft-deprecated. The shared singleton
  forces every feature in the process onto a single
  `DownloadConfiguration`, which prevents per-feature retry budgets,
  cellular policies, or storage roots. Prefer constructing per-feature
  managers via ``DownloadManager.make(configuration:)``. The symbol
  remains available for the entire 4.x line so existing call sites
  continue to compile with a deprecation warning.

### Fixed

- Macro diagnostics emitted by `@APIDefinition` and `#endpoint` now attach
  their `SourceLocation` to the offending syntax node (the missing
  argument list, the non-literal `path:` expression, the unlabeled
  `as:` argument, etc.) instead of falling back to a generic location
  on the macro attribute. IDE squiggles and `swift build` diagnostics
  now point at the exact argument the user has to fix.
- `CircuitBreakerRegistry.recordStatus(...)` no longer resets the rolling
  failure window on 4xx responses. 4xx is now a no-op (the transport worked,
  the failure is semantic), 5xx still counts as a transport failure, and
  2xx/3xx clear the accumulated failures and release any half-open probe
  slot. Previously a single 4xx interleaved between 5xx/timeout failures
  could mask a host that was teetering on the failure threshold.
- `TimeoutReason` documentation now enumerates the exact `URLError` →
  `NetworkError.timeout(reason:)` mapping (`.timedOut` →
  `.requestTimeout`, `.cannotConnectToHost` → `.connectionTimeout`) and
  records why other transport codes (DNS failures, reachability errors,
  mid-flight drops) intentionally surface as `NetworkError.underlying`
  instead of being reclassified as timeouts. Lock-down tests cover
  `URLError.cancelled`, `.networkConnectionLost`, and
  `.notConnectedToInternet`.
- `DownloadTask.updateState(_:)` now validates transitions against the
  documented `DownloadState.canTransition(to:)` table. Illegal transitions
  trigger `assertionFailure` in DEBUG and an OSLog `.fault` in release,
  then reject the assignment so the existing state is preserved. State
  restoration (rebuilding actor state from persisted records or live
  `URLSession` task state on relaunch) and test-only state injection now
  use the new `restoreState(_:)` helper, which bypasses validation.

## [4.0.0]

InnoNetwork's first public release. The package targets Apple platforms only
and is built around Swift Concurrency, explicit transport policies, and
operational visibility from prototype to production. See
[`docs/releases/4.0.0.md`](docs/releases/4.0.0.md) for the one-page release
summary.

### Added

- Internal request execution pipeline stages for built-in preflight,
  transport, post-transport, status validation, and decode handling. The
  generic pipeline remains package/internal; no public `RequestExecutionPolicy`
  protocol is exposed.
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
  initializer with a more discoverable name. `DownloadManager.shared`
  logs an OSLog `.fault`, asserts in DEBUG, and falls back to a
  process-unique identifier on duplicate-session-identifier conflicts so the
  singleton stays usable.
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
  site lives at https://innosquadcorp.github.io/InnoNetwork/.
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
- CI `apple-platform-build-smoke` job covers macOS, iOS, tvOS, watchOS, and
  visionOS build-only smoke validation.
- Release artifacts (`benchmarks.json`, `sbom.cdx.json`) are signed with
  sigstore cosign keyless signatures. SECURITY.md describes the
  `cosign verify-blob` invocation.
- `CancellationTag` plus `DefaultNetworkClient.request(_:tag:)`,
  `upload(_:tag:)`, and `cancelAll(matching:)` for grouping requests so a
  screen, feature, or user session can drop just its own subset without
  draining the rest of the client.
- Response cache honours the response `Vary` header (RFC 9111 §4.1).
  `Vary: *` responses are not stored, and concrete `Vary` headers capture a
  request-header snapshot that future lookups must match. Helpers
  `evaluateVary(responseHeaders:request:)` and
  `cachedResponseMatchesVary(_:request:)` are package-scoped utilities.

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

### Removed

- `NetworkError.undefined` and `NetworkError.jsonMapping` — both cases were
  unreachable in production code and only existed as test fixtures.
  `.objectMapping(error, response)` covers every JSON decode failure.

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
