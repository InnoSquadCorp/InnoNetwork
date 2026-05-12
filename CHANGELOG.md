# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and the project follows Semantic
Versioning.

## [Unreleased]

### Added

- `WebSocketError.reconnectSleepFailed(SendableUnderlyingError)` case. The
  reconnect coordinator previously published `.error(.unknown)` whenever
  its backoff sleep itself failed for a reason other than cancellation,
  hiding the underlying clock/sleep failure from observers. The new
  typed case carries the original error so telemetry can correlate the
  skipped reconnect attempt with its root cause; `LocalizedError`
  output now reports `WebSocket reconnect backoff sleep failed: …`.

- `NetworkErrorCode` SSOT enum in `Sources/InnoNetwork/NetworkErrorCode.swift`.
  Owns every `NetworkError.errorCode` raw value (`1001`/`1002`/`1003`,
  `2002`/`2003`, `3001`/`3002`, `4001`/`4002`/`4003`/`4004`/`4005`, `5001`) — the inline
  literals previously sprinkled across `RequestExecutor`,
  `BufferedAsyncBytes`, `StreamingExecutor`, and `VCRURLSession` now
  route through the enum. `.cancelled` and `.timeout` now also return
  InnoNetwork-owned codes instead of borrowing Foundation `URLError`
  constants. The `2001` slot is intentionally vacant for historical
  compatibility (documented in a comment on the enum).
- `NetworkError.reachability(ReachabilityReason, SendableUnderlyingError, Response?)`
  case classifying `URLError.notConnectedToInternet`,
  `.dnsLookupFailed`, `.cannotFindHost`, and `.networkConnectionLost`.
  `mapTransportError(_:taskInterval:resourceTimeoutInterval:)` routes
  the four `URLError.code`s into the new case **before** the timeout
  /`cannotConnectToHost` arms so callers stop classifying connectivity
  loss as transport timeouts. `errorCode` is `4002`. The
  `WebSocketCloseDisposition.isTransientNetworkError` classifier now
  pattern-matches on `.reachability` rather than scrubbing
  `URLError.code` substrings out of `.underlying`.
- `MultipartUploadStrategy.inMemory(maxBytes:)` requires an explicit
  byte cap; the encoder now records every written part against a
  running counter and throws `NetworkError.configuration(.invalidRequest(...))`
  the moment the accumulator exceeds `maxBytes`, closing the
  estimator-vs-read TOCTOU window that previously allowed swapped or
  late-grown file parts to bypass the pre-flight estimate.
- `DownloadConfiguration.taskInactivityTimeout: Duration?` watchdog.
  When non-nil, `DownloadManager` starts a detached monitor that
  cancels the underlying `URLSessionDownloadTask` (and emits the
  same `NetworkError.cancelled` event the user-driven cancel path
  emits) whenever no progress has been reported for the configured
  window. `DownloadTask.lastProgressAt: ContinuousClock.Instant?`
  exposes the most recent progress timestamp for diagnostics.
- `DownloadConfiguration` gained `sharedContainerIdentifier: String?`
  and the matching `AdvancedBuilder` field. The value maps to
  `URLSessionConfiguration.sharedContainerIdentifier` for App Group
  background sessions; defaults stay `nil`, and existing construction
  sites continue to compile.
- `ResponseCachePolicy.rfc9111Compliant(wrapping:)` directive-aware
  adapter. Wraps any existing policy and adds opt-in support for
  RFC 9111 directives on top of the inner freshness window:
  `Cache-Control: no-store` forces revalidation, `must-revalidate`
  demotes `.returnStaleAndRevalidate` to `.revalidate`, and
  `max-age=N` clamps freshness to `min(server, inner)`. When no valid
  `max-age` exists, `Expires` falls back to `Expires - Date` or
  `Expires - storedAt`; when neither exists, `Last-Modified` applies the
  RFC 9111 §4.2.2 10% heuristic capped at 24 hours. Invalid freshness
  metadata is stale. Documented in `docs/rfcs/RFC9111-Compliance.md`.
- `ResponseCache.invalidateTargetURI(_:)` requirement with a default
  implementation for custom caches. The built-in in-memory and
  persistent caches override it to remove every method/header variant
  whose normalized target URI matches.
- `NetworkConfiguration.streamingLineByteLimit` and
  `TransportPack.streamingLineByteLimit` configure the maximum UTF-8 byte
  length for one line-delimited streaming frame. The default remains
  1 MiB and values below 1 clamp to 1.
- OpenAPI generator now emits explicit `APIResponse = EmptyResponse`
  for operations declaring `202` or `204` responses (previously
  collapsed onto a generic fallback).
- `JWTBearerInterceptor` reference signer in `Sources/InnoNetwork/Auth/`.
  Wraps an `async throws -> String` token-mint closure and writes the
  resulting token into `Authorization: Bearer <token>` (or any
  scheme/header pair the caller supplies). Use this for the
  request-minted JWT lane only — session-rotated bearer tokens are
  still better served by `RefreshTokenPolicy`'s single-flight refresh.
  Listed as Provisionally Stable in API_STABILITY.md.
- `AWSSigV4Interceptor` reference signer in `Sources/InnoNetwork/Auth/`.
  Targets the single-shot, in-memory body flow that covers most AWS
  service calls (DynamoDB, S3 GET, CloudWatch, SQS). Streaming SigV4
  (`STREAMING-AWS4-HMAC-SHA256-PAYLOAD`) and presigned URL signing are
  out of scope and intentionally not implemented; adopters that need
  them should fall back to the AWS SDK or a purpose-built signer. The
  interceptor exposes `canonicalRequest(for:)` and
  `stringToSign(canonicalRequest:date:)` as test probes so the
  implementation can be validated against the published AWS SigV4
  test vectors before shipping to production. Listed as Provisionally
  Stable in API_STABILITY.md.
- Package-internal `NetworkError` classification helpers for category,
  retry hint, and user-visible hint decisions. The public error shape
  is unchanged; the helper centralizes policy branching that previously
  lived at call sites.
- `Examples/TargetTypeCatalog`, a Moya-style catalog migration recipe
  that maps enum cases to concrete `APIDefinition` values before typed
  request execution.
- `Scripts/check_provisional_enum_cases.sh` plus an enum-case allowlist
  for guarded public/provisionally-stable cases. CI and release checks
  now fail if a guarded case changes without an explicit ledger update.

### Fixed

- Multipart `.inMemory` strategy now blocks the estimator-vs-read TOCTOU
  window: previously a file part whose size grew between estimate and
  read could exceed the configured ceiling; the new per-write
  accumulator guard refuses the encode as soon as the cap is breached.
- `ResponseCache` now follows RFC 9111 §4.4 for unsafe-method
  invalidation: `POST` / `PUT` / `PATCH` / `DELETE` and safety-unknown
  methods invalidate stored responses for the request target URI after
  2xx/3xx origin responses when cache writes are enabled. `.disabled`
  and `.networkOnly` still leave cache metadata untouched.
- Responses to requests carrying `Authorization` are no longer stored unless
  the origin explicitly permits it with `Cache-Control: public`,
  `must-revalidate`, or `s-maxage`. `storesAuthenticatedResponses: true`
  remains the persistent-cache privacy opt-in, but it does not bypass the
  RFC 9111 §3.5 permission gate.
- `RetryIdempotencyPolicy.safeMethodsAndIdempotencyKey` now includes
  `OPTIONS` and `TRACE` alongside `GET` and `HEAD`. `PUT` and `DELETE`
  remain protected by `Idempotency-Key` or explicit method-agnostic retry.
- `RefreshTokenCoordinator` awaiters now observe caller cancellation promptly
  without cancelling a shared refresh for other waiters. If the coordinator is
  released while a refresh is still in flight, the orphan refresh task is
  cancelled.
- `TaskStartGate.wait()` is cancellation-aware. Awaiters cancelled before
  `open()` now resume with `false` instead of leaving a continuation behind.
- `ConcurrencyTokenBucket` now synchronously records cancellation before the
  actor cleanup hop, preventing a queued waiter from being resumed by a
  racing `release()`.
- `InFlightRegistry` registration now checks a generation token captured before
  suspension. Late registrations after `cancelAll()` or tagged cancellation are
  cancelled immediately instead of re-entering the in-flight table.
- `PersistentResponseCache` open-time budget enforcement now uses running total
  byte accounting while evicting large indexes instead of recomputing total
  bytes on every victim.
- `DownloadManager` now stores its transfer, restore, and failure
  coordinators once during initialization instead of recreating them through
  computed properties on every access.
- `DownloadManager.shutdown()` is now race-safe under concurrent calls.
  The shutdown flag moved from actor-isolated state to a
  `nonisolated OSAllocatedUnfairLock<Bool>` mirroring the
  `WebSocketManager` pattern, so a `shutdown()` and a `deinit` racing
  through the cleanup path no longer double-invalidate the session.
- `DefaultNetworkClient.perform(executable:tag:)` now passes the injected
  `RequestExecutionRuntime` clock into `RetryCoordinator`, so generated-client
  retry timing follows the same deterministic test clock as the hand-written
  request path.
- `RestoreBarrier` cancellation no longer registers a second detached task
  after the cancellation task may already have completed. Cancelled restore
  waiters are removed idempotently by waiter id, preventing stale cancellation
  handles from accumulating during cancel storms.

### Stability ledger

- Promoted from Provisionally Stable to Stable in 4.x.x:
  `EndpointBuilder` and `EndpointPathEncoding`, `DecodingInterceptor`,
  and `WebSocketCloseDisposition`. These surfaces have been shipping
  unchanged since 4.0.0 and now carry the SemVer-protected contract;
  consumers can pin `.upToNextMajor(from: "4.0.0")` and rely on them
  remaining source-compatible across the 4.x line.
- Added an explicit "no 5.0 major bump is planned in the 4.x line"
  callout to API_STABILITY.md. The Stable ledger only grows over the
  rest of 4.x; entries do not move back into Provisionally Stable.
- Removed stale Stable Examples wording referencing
  `Examples/CustomHeaders` and `Examples/RealWorldAPI`, which were
  deleted earlier in this PR.

### Changed

- **Breaking.** `MultipartUploadStrategy.inMemory` no longer accepts a
  zero-argument form. Adopters must migrate to
  `.inMemory(maxBytes: <Int>)` (or switch to
  `.platformDefault` / `.streamingThreshold(bytes:)`). The compiler
  surfaces the migration site as "missing argument for parameter
  `maxBytes`". Rationale: the previous `.inMemory` call site silently
  defaulted to `Int.max`, allowing a single oversized part to OOM the
  process; the new mandatory cap forces an explicit ceiling and is
  paired with a runtime accumulator guard. See `docs/Migration-4.1.0.md`.
- **Breaking.** The OpenAPI generator now rejects path templates
  (`/users/{id}`, `/orders/{orderID}/items`) at generation time with
  `GenerationError.unsupportedPath`. Previously the placeholder was
  emitted verbatim into the generated `path` string, which produced
  surprising runtime 404s when the operation was invoked without
  substitution. Adopters that need templating should hand-roll the
  `path` property (delete the generator output and check in the
  hand-written variant). See `docs/Migration-4.1.0.md`.
- **Breaking.** `PublicKeyPinningEvaluator` no longer identifies
  Ed25519 keys via the lowercase `"ed25519"` keyword string. Only the
  RFC 8410 OID `1.3.101.112` matches. Adopters who fed a private CA
  identifier string into the SPKI encoder must switch to the OID.
  Rationale: the loose keyword match risked collisions with future
  `Security.framework` constants that happen to contain `"ed25519"` as
  a substring; the OID-only path is stable forever. See
  `docs/Migration-4.1.0.md`.
- **Breaking.** `ConcurrencyTokenBucket.acquire()` is now
  `async throws`. A queued waiter that is cancelled is removed from
  the FIFO queue and receives `CancellationError` instead of later
  consuming a token. Direct callers must migrate from
  `await bucket.acquire()` to `try await bucket.acquire()`. See
  `docs/Migration-4.1.0.md`.
- `ConcurrencyLimitExecutionPolicy` now awaits `bucket.release()` before
  returning or rethrowing. The previous implementation used an
  unstructured `Task` from `defer`, which made the release boundary
  observable only after a scheduler hop.
- Stable example smoke builds now pass `-Xswiftc -warnings-as-errors` so
  copyable contract examples cannot drift with compiler warnings.
- `RequestExecutor.execute(...)` is split into prepare, response, and decode
  stages while preserving request policy behavior.
- `NetworkConfiguration.recommendedForProduction(baseURL:)` now caps
  streaming response body collection at 5 MiB by default. Callers that
  need larger inline bodies can still override the policy through
  `advanced(baseURL:resilience:...)` or the `responseBodyLimit` alias.
- `NetworkConfiguration` now has `makeURLSessionConfiguration()` mirror
  its session-level timeout, cache policy, cellular, expensive-network,
  and constrained-network defaults. Trust policy remains a per-task
  delegate concern and is not representable on `URLSessionConfiguration`.
- `InnoNetworkClientTransport` now returns generated-client response
  bodies as streaming `HTTPBody` values backed by `URLSession.bytes(for:)`.
  `Content-Length` can fail the `responseBodyByteLimit` guard before the
  body is returned; unknown-length responses enforce the same limit while
  the generated client consumes the stream. Request bodies remain bounded
  collected payloads.
- `PersistentResponseCache` now stores `Vary` variants under separate
  disk identifiers instead of letting later variants overwrite earlier
  ones for the same method and target URI. Existing single-variant entries
  keep their legacy identifiers and are re-indexed on open when a concrete
  `Vary` snapshot is present.
- `WebSocketCloseCode.noStatusReceived` (`1005`) now maps to
  `.peerRetryable` because it represents an absent close status rather
  than a peer protocol violation. Heartbeat ping timeout handling now
  enters the same delegate-event queue as Foundation callbacks, preserving
  FIFO ordering with connect, close, and error events.
- **Breaking.** `NetworkClient.request(_:)`, `request(_:tag:)`,
  `upload(_:)`, and `upload(_:tag:)` now declare `throws(NetworkError)`
  instead of untyped `throws`. The four methods only ever surfaced
  `NetworkError` in practice (`RetryCoordinator` normalises every
  classified failure, foreign errors are mapped at the
  `DefaultNetworkClient` boundary), so the new typed-throws clause makes
  that contract explicit and lets adopters catch with
  `catch let error as NetworkError` (no `@unknown default` cast) or
  `catch` to handle the typed value directly. Existing call sites that
  used `try await client.request(...)` continue to compile; conforming
  mocks must update their method signatures to
  `async throws(NetworkError)`. `NetworkError.mapTransportError(_:)` is
  now `public` so out-of-package conformers can map raw
  `URLError`/`CancellationError` to the canonical `NetworkError` case.
- **Breaking.** `NetworkConfiguration.AdvancedBuilder` is no longer
  public. The closure-based factory
  `NetworkConfiguration.advanced(baseURL:_:)` was removed; the new
  public entry point is
  `NetworkConfiguration.advanced(baseURL:resilience:auth:observability:cache:transport:)`,
  composing the five `ResiliencePack` / `AuthPack` / `ObservabilityPack`
  / `CachePack` / `TransportPack` value types as named arguments. The
  packs now carry the full configuration surface — `TransportPack`
  gained `trustPolicy`, `acceptableStatusCodes`, `userAgentProvider`,
  `acceptLanguageProvider`; `ResiliencePack` gained
  `customExecutionPolicies`; `AuthPack` gained
  `additionalResponseInterceptors` and `additionalDecodingInterceptors`.
  Adopters who used the closure-form factory migrate by replacing each
  `builder.<field> = value` mutation with the equivalent named pack
  field. The seven `NetworkConfiguration.with(...)` chainable modifiers
  are unchanged.
- **Breaking.** Public-key pinning moved out of `InnoNetwork` into a
  dedicated `InnoNetworkTrust` companion product. `PublicKeyPinningPolicy`,
  `PublicKeyPinningPolicy.HostMatchingStrategy`, and the new
  `PublicKeyPinningEvaluator: TrustEvaluating` (which carries the SPKI
  hashing, host-match, and `SecTrustEvaluateWithError` machinery) now
  live in `Sources/InnoNetworkTrust/`. Apps relying on Apple's ATS
  defaults link only `InnoNetwork` and no longer pay the
  `Security`/`CryptoKit` symbol cost. Adopters that pin migrate by
  adding the `InnoNetworkTrust` product to their target dependencies,
  `import InnoNetworkTrust`, and feeding the evaluator into
  `TrustPolicy.custom(_:)`.
- **Breaking.** `TrustPolicy.publicKeyPinning(_:)` was removed in the
  same change. The replacement is
  `TrustPolicy.custom(PublicKeyPinningEvaluator(policy: ...))`. There is
  no `@_exported` re-export shim — callers who used the old enum case
  must update their construction site.
- **Breaking.** `TrustEvaluating.evaluate(challenge:)` now returns
  `TrustChallengeOutcome` (a new public enum: `.performDefaultHandling`,
  `.useCredential`, `.cancel(TrustFailureReason)`) instead of `Bool`.
  This preserves the granular pinning failure reasons
  (`.pinMismatch`, `.hostNotPinned`, `.publicKeyExtractionFailed`,
  `.systemTrustEvaluationFailed`) when custom evaluators run, so
  observability/telemetry consumers see the same `NetworkError.
  trustEvaluationFailed` taxonomy after the split.

### Removed

- **Breaking.** `NetworkError.cacheRevalidationFailed(underlying:cached:)`
  has been removed. The internal `RequestExecutor.cacheRevalidationFailed`
  helper now returns
  `.underlying(SendableUnderlyingError(domain: "InnoNetwork.ResponseCache", code: 304, message: "Cache revalidation against the stored response failed: \(message)"), cachedResponse)`
  for the same conditions; pattern-match on `.underlying(let underlying, let cached?)`
  with `underlying.domain == "InnoNetwork.ResponseCache"`. The
  Localizable.strings key, the API_STABILITY ledger entry, the
  allowlist entry, and the docs-contract-sync mapping are removed
  alongside the case. NetworkError surface is now **7 cases** —
  the original plan E target (11 → 7) is complete.
- **Breaking.** `NetworkError.responseTooLarge(limit:observed:)` has
  been removed. The buffer-overflow throw sites in `BufferedAsyncBytes`
  and `RequestExecutor` now throw
  `.underlying(SendableUnderlyingError(domain:, code: 4003, message:), nil)`
  with the limit and observed byte counts in the message; pattern-
  match on `.underlying(let underlying, _)` with
  `underlying.code == 4003`. The dedicated Localizable.strings key,
  the corresponding allowlist entry, and the ErrorClassification.md
  row are removed alongside the case.
- **Breaking.** `NetworkError.transportSuspended` has been removed.
  `ReachabilityCheckExecutionPolicy` now throws
  `NetworkError.underlying(SendableUnderlyingError(domain:, code: 4002, message:), nil)`
  for the same condition (`.requiresConnection` persisting past
  `suspensionWaitTimeout`); pattern match on `.underlying(let underlying, _)`
  with `underlying.code == 4002` to detect it. The dedicated
  `NetworkError.transportSuspended` Localizable.strings key, the
  matching API_STABILITY ledger entry, and the allowlist entry are
  removed alongside the case. The 4.0.0 migration document and the
  4.0.0 release note retain their historical mentions; only the
  current contract loses the case.
- **Breaking.** `NetworkConfiguration.urlSessionConfigurationOverride`,
  the matching field on `AdvancedBuilder`, and the
  `urlSessionConfigurationOverride` parameter on
  `NetworkConfiguration.init(...)` and `TransportPack.init(...)` have
  been removed. The hook was a leaky
  abstraction over raw `URLSessionConfiguration` and overlapped with
  the existing explicit-session path. Migration: build a configuration
  from `NetworkConfiguration.makeURLSessionConfiguration()`, mutate it
  directly (`httpCookieStorage` for cookie isolation, `assumesHTTP3
  Capable` for HTTP/3 opt-in, `tlsMinimumSupportedProtocolVersion`
  for TLS, etc.), and inject the resulting `URLSession` via
  `DefaultNetworkClient(configuration:session:)`. The pattern is the
  same one already documented in `docs/Cookies.md`,
  `docs/HTTP3.md`, and `docs/AppGroupSharedSession.md`. The dedicated
  `docs/UrlSessionEscapeHatchAlternatives.md` cookbook is removed
  alongside the surface; its content is now folded into the
  configuration articles.
- **Breaking.** `NetworkError.nonHTTPResponse(URLResponse)` has been
  removed. Adopters that pattern-matched on `.nonHTTPResponse` should
  match on `.underlying(let underlying, _)` and inspect
  `underlying.code == 3002` (the dedicated non-HTTP-response code).
  All built-in throw sites (`RequestExecutor`, `StreamingExecutor`,
  `VCRURLSession`) now wrap the bare `URLResponse` into a
  `SendableUnderlyingError` with code `3002` and a diagnostic message
  carrying the request URL and response type. The case was marked
  deprecated earlier in this PR; it is removed in the same PR per the
  maintainer's "no zombie deprecations" cleanup pass.

### Localization

- `NetworkError.errorDescription` no longer ships a Korean
  (`ko.lproj/Localizable.strings`) translation. Only the English
  catalogue remains. The library scope makes per-language translations
  difficult to keep complete and aligned across releases, so the
  recommendation is for adopters to localize error messages in their
  own application layer where they already control copy review.
  Korean-language adopters lose the localized `errorDescription` text;
  the keys themselves are unchanged so any per-app localization that
  reads from the catalogue continues to compile.

### Added (release/4.0.0-batch)

- **Download lifecycle epoch tracking.** `DownloadTask` exposes
  `generation` / `attempt` accessors for observing manager-maintained
  retry/resume epochs. The internal download lifecycle bookkeeping
  reduces through `DownloadLifecycleReducer` and applies an
  `.advancedEpoch` effect.
  The reducer gains a `.startAttempt` event and an `.advancedEpoch`
  effect; epoch advancement is orthogonal to the state-transition
  table so retries can begin from any pre-attempt state without
  widening `canTransition`.
- **Persistent cache hit/miss/eviction metrics.**
  `PersistentResponseCacheStatistics` adds three monotonic in-process
  counters: `hitCount`, `missCount`, and `evictionCount`. The cache
  actor seeds the eviction counter from the open-time scrub pipeline.
- **NetworkConfiguration fluent modifiers.** Seven additive
  modifiers — `with(retry:)`, `with(cache:)`, `with(circuitBreaker:)`,
  `with(refresh:)`, `with(coalescing:)`, `with(executionPolicies:)`,
  `with(eventObservers:)` — wrap the existing `AdvancedBuilder`.
- **`StreamingResumeStrategy` protocol.** Marker protocol with a
  single `isCompatible(with bufferingPolicy:)` requirement;
  `StreamingResumePolicy` retroactively conforms. The streaming
  executor's bounded-buffer guard now flows through the protocol.
- **Ordered event sequence ID.** `NetworkEventHub` allocates a
  monotonic `UInt64` sequence ID on every publish call and threads it
  through partition queues and observer chains.
- **`MultipartUploadStrategy.threshold(bytes:)`** clamping factory and
  explicit visionOS branch on `platformDefault`.
- **`HTTPHeaderName<Variant>` phantom-typed keys.** Parallel
  type-safe header API alongside the existing `String`-keyed surface;
  `SingleValueHeader` names route through `update`,
  `RepeatableHeader` names expose only the append helper.
- **5.0 design note for `apple/swift-openapi-generator`** at
  `Tools/openapi-to-innonetwork/SwiftOpenAPIGeneratorPath.md`.
- **Five-policy compatibility matrix** in `docs/PolicyInteractions.md`.
- **RFC 9111 compliance matrix** at
  `docs/rfcs/RFC9111-Compliance.md`.

### Changed (release/4.0.0-batch)

- **`RequestExecutor` consolidation.** Four lifecycle-stage extension
  files merged into a single `RequestExecutor.swift` with MARK-
  divided sections. Public/package surface unchanged.
- **`PersistentResponseCache` split** into five focused files; actor
  body shrinks 1,132 -> 843 lines. `applyDataProtection` is promoted
  from `fileprivate` to module-internal so the relocated KeyNormalizer
  can request the same protection class.
- **`WebSocketManager` helper extraction.** Top-level public DTOs and
  the file-private `WebSocketInvalidationBarrier` actor move to
  dedicated files; manager body shrinks 1,201 -> 1,059 lines as a
  prep for the actor conversion below.

### Breaking (release/4.0.0-batch)

- **`WebSocketManager` is now an `actor`.** Every public entry point
  requires `await` from the call site:

  ```swift
  let task = await manager.connect(url: url)
  for await event in await manager.events(for: task) { ... }
  await manager.disconnect(task)
  ```

  The four URLSession delegate-bridge methods and
  `handleBackgroundSessionCompletion` stay `nonisolated`.

- **`NetworkError` adds `.transportSuspended` and
  `.cacheRevalidationFailed(underlying:cached:)`.** The enum has been
  documented as non-`@frozen` since the type was introduced; this
  release exercises that contract for the first time. Adopters that
  ignored the recommendation see a "Switch must be exhaustive" warning
  until they add the new arms or wrap with `@unknown default`.
  `.transportSuspended` is emitted when `.requiresConnection` persists
  through the reachability policy wait.
  Localized strings ship in `en` and `ko`.

- **Streaming bounded-buffer guard message.** Runtime guard moved
  from a hardcoded `StreamingResumePolicy.lastEventID` switch to the
  new `StreamingResumeStrategy.isCompatible(with:)` protocol method.
  The thrown `NetworkError.configuration(.invalidRequest(...))` now
  reads "StreamingResumePolicy requires unbounded output buffering ...".

- **Package.swift platform-floor comment correction.** No code
  change; the comment claimed `4.x bumped to iOS 18 / macOS 15 / ...`
  while the declared values were always iOS 16 / macOS 14 / .... The
  comment was a stale draft.

### Added

- Privacy manifests (`PrivacyInfo.xcprivacy`) declaring the
  `NSPrivacyAccessedAPICategoryFileTimestamp` Required Reason API for the
  `InnoNetwork`, `InnoNetworkDownload`, and `InnoNetworkPersistentCache`
  targets. The library inspects file metadata via
  `FileManager.attributesOfItem(...)` on app-container files
  (`MultipartFormData` part sizing, `DownloadTaskPersistence` resume metadata,
  `PersistentResponseCache` size accounting), so the manifest pre-declares
  reason `C617.1`. Consumers no longer have to author this declaration when
  shipping apps that link InnoNetwork.
- "Stable Examples" contract in `API_STABILITY.md` carving out
  `Examples/BasicRequest`, `Examples/Auth`, and `Examples/ErrorHandling` as
  SemVer-protected starting points. Their directory layout (Swift sources +
  `README.md`) is enforced by the new `Scripts/check_stable_examples.sh`
  guard, wired into the existing `docs-contract-sync` CI job. Wording is
  not contractual, but the copyable Swift examples now compile against the
  current public package in CI.
- `NetworkClient.request(_:method:tag:)` convenience overload that infers
  the response type from the call-site annotation. Builds a default
  `EndpointBuilder` on the fly with `PublicAuthScope` and the method's
  default `TransportPolicy`, so simple GETs read like
  `let user: User = try await client.request("/users/\(id)")`. Endpoints
  that need authenticated scopes, custom headers, body parameters, or
  per-endpoint interceptors should keep using `EndpointBuilder` or
  a hand-written `APIDefinition`.

- `Tools/openapi-to-innonetwork` expands beyond the 4.x preview:
  - YAML input (Yams 5.0+) is now supported alongside JSON; the format
    is inferred from the file extension. The runtime library still
    pulls in zero codegen dependencies because Yams lives only inside
    the standalone `Tools/` package.
  - The schema model now parses `components.schemas`, per-operation
    `requestBody.content["application/json"].schema`, and
    `responses["200"|"201"].content["application/json"].schema`.
  - Generated output adds one Swift file per
    `components.schemas` entry (Codable struct mirroring the OpenAPI
    properties — required fields are non-optional, optional fields
    default to `nil`). Operation files now wire typed `Parameter` and
    `APIResponse` aliases when the spec uses `$ref`, and fall back to
    `EmptyParameter` / `EmptyResponse` otherwise. Property types map
    string / integer / number / boolean / array / `$ref` plus the
    common format hints (`int64`, `date-time`, `uri`); unsupported schema
    properties generate a companion `AnyCodable` fallback so the emitted
    module still compiles.
  - The README and CI usage examples now show YAML input directly
    (no more `yq` workaround).
- `Tools/openapi-to-innonetwork` ships a 4.x preview of an OpenAPI 3
  → `APIDefinition` Swift code generator. Standalone SwiftPM
  executable living outside the root package so the runtime library
  never resolves codegen dependencies; reads a JSON-encoded subset of
  OpenAPI 3 (paths/operations with `operationId` + `summary`), emits
  one Swift file per operation conforming to `APIDefinition` with
  `EmptyParameter` / `EmptyResponse` defaults that adopters fill in
  during integration. `docs/CodeGeneration.md` documents the
  decision matrix between hand-written endpoints, this preview tool,
  and the existing `@_spi(GeneratedClientSupport)` SPI route. The
  CI consumer-smoke job builds and tests the tool to keep regressions
  visible. `Scripts/format.sh` includes `Tools/` in the lint scope.
- `Sources/InnoNetwork/InnoNetwork.docc/Articles/OfflineHandling.md`
  documents three offline-aware patterns on top of the existing
  `NetworkMonitoring` protocol: inspect-and-skip for background
  prefetch, fail-fast `RequestInterceptor` for interactive flows,
  and wait-for-recovery wrapping around an existing `RetryPolicy`
  for non-interactive batch traffic. Explains why the library
  intentionally does not ship a built-in `OfflineQueuePolicy`
  (idempotency / cookie scoping / quota / TTL are
  backend-shaped) and pairs each pattern with the cellular vs
  reachability decision via `NetworkSnapshot.interfaceTypes`.
  Linked from the topic group between `<doc:RequestSigning>` and
  `<doc:CachingStrategies>`.
- `Sources/InnoNetwork/InnoNetwork.docc/Articles/RequestSigning.md`
  walks through wiring `HMACRequestInterceptor` and building a custom
  canonical signer (timestamp + nonce + body hash + URL path) on top
  of the same `RequestInterceptor` contract, including the streaming-
  upload alternatives (hash during multipart construction, signed
  manifest, chunk-signed protocol). Linked from the main DocC topic
  group between `<doc:AuthRefresh>` and `<doc:CachingStrategies>`.
- `HMACRequestInterceptor` — reference HMAC body-signing
  `RequestInterceptor` for backends that authenticate requests with a
  shared secret (webhooks, internal RPC gateways, lightweight API
  gateways). Supports SHA-256 / SHA-384 / SHA-512 over the request
  body and emits the signature plus a key identifier into
  caller-tunable headers (`X-Signature` / `X-Signature-Key-Id` by
  default). Streaming bodies (`URLRequest.httpBodyStream`) are
  rejected with `NetworkError.configuration(reason: .invalidRequest(...))`
  rather than silently signing an empty payload — production protocols
  needing AWS SigV4, OAuth1, or similar canonicalization should ship as a
  dedicated interceptor on top of the same `RequestInterceptor` contract.
  Composes through `NetworkConfiguration.requestInterceptors` alongside any
  existing auth chain (`RefreshTokenPolicy`, custom adapters).
- `NetworkError.configuration(reason:)` and the matching
  `NetworkConfigurationFailureReason` enum (`invalidBaseURL`,
  `invalidRequest`, `offline`). Adopters can now switch on the
  consolidated ledger shape directly. The legacy
  `NetworkError.invalidBaseURL` and
  `NetworkError.invalidRequestConfiguration` cases are not available in
  `4.0.0`; switch on the reason payload instead.
  `ReachabilityCheckExecutionPolicy` emits
  `.configuration(reason: .offline(_:))` so the offline failure mode surfaces
  through the consolidated case from day one. English/Korean
  Localizable.strings ship a new `NetworkError.offline` key shared by the
  offline reason.

### CI / Tooling

- `Scripts/check_no_print_in_production.sh` enforces a `print()` ban
  across the four shipping library targets (`InnoNetwork`,
  `InnoNetworkDownload`, `InnoNetworkPersistentCache`,
  `InnoNetworkWebSocket`). Operational logging stays on
  `NetworkLogger` / `OSLogNetworkEventObserver`; smoke targets,
  tests, examples, benchmarks, and DocC tutorial code snippets keep
  their `print()` calls (they live outside the production source
  tree or under `*.docc/Resources/`). Wired into the existing
  `build-and-test` CI job alongside the
  `check_production_force_unwraps.sh` gate.

### Changed

- `docs/Migration-5.0.0.md` now reflects that the endpoint vocabulary and
  `NetworkError` ledger reset landed in `4.0.0`. It keeps the future 5.0
  notes focused on remaining pack/codegen evolution and directs consumers to
  migrate old endpoint/error spellings before adopting this release.
- `CLAUDE.md` updates the project-context platform floors to match
  the 4.x backport (iOS 16 / macOS 14 / tvOS 16 / watchOS 9 /
  visionOS 1).
### Documentation (continued)

- `NetworkError`'s top-level doc comment now states that the enum is
  intentionally non-`@frozen`, documents the current
  `configuration(reason:)` shape, and includes a worked `@unknown default`
  switch pattern for future failure modes.

### Removed (BREAKING)

- `EndpointShape` is renamed to `Endpoint` (the protocol), removing
  the legacy spelling outright. `EndpointAuthScope` is renamed to
  `AuthScope`. `ScopedEndpoint<R, S>` is renamed to
  `EndpointBuilder<Response, Scope>`. `Sources/InnoNetwork/RenamedAliases.swift`
  (the 4.x forward-compat typealias bundle) is deleted; there is no
  deprecated alias path. Every in-tree call site (Sources, Tests,
  Examples, smoke targets) is migrated to the new names in this
  commit. The two concrete auth scopes (`PublicAuthScope`,
  `AuthRequiredScope`) keep their names. Generic-parameter shadowing
  on `EndpointBuilder` (the old `AuthScope` generic param colliding
  with the renamed protocol) is fixed by renaming the generic
  parameter to `Scope`.
- `NetworkError.invalidBaseURL(_:)` and
  `NetworkError.invalidRequestConfiguration(_:)` are removed. Adopters
  switch on `NetworkError.configuration(reason:)` and the matching
  `NetworkConfigurationFailureReason` cases
  (`.invalidBaseURL` / `.invalidRequest` / `.offline`) instead. Every
  in-tree call site (28 files: throw sites, catch blocks, doc smoke
  targets, tests) is migrated to the consolidated shape in this
  release. The legacy spelling is no longer available — there is no
  deprecated alias path; consumer code that pattern-matched the
  removed cases needs to switch to the reason-based shape directly.

### Added (continued)

- `ReachabilityCheckExecutionPolicy` — executor-integrated
  reachability gate. Reads `NetworkMonitoring.currentSnapshot()`
  before each transport attempt and throws
  `NetworkError.configuration(reason: .offline(...))` when the path is
  `.unsatisfied`, so requests fail fast instead of burning URLSession's
  timeout on a known-offline path. Two modes:
  `.requireOnline` rejects, `.warnOnly` lets the request proceed
  for staged rollouts that want telemetry first. `.requiresConnection`
  waits up to `suspensionWaitTimeout` before forwarding, surfacing
  offline, or throwing `.transportSuspended`; unobserved snapshots fall
  through.
  Four unit tests cover the four state transitions
  (offline / online / warn-only / nil snapshot).
- `ConcurrencyLimitExecutionPolicy` — executor-integrated
  counterpart of `ConcurrencyTokenBucket`. Implements
  `RequestExecutionPolicy` so adopters register the policy on
  `NetworkConfiguration.AdvancedBuilder.customExecutionPolicies`
  instead of pairing a request and response interceptor manually.
  `acquire` is awaited before forwarding to the rest of the chain;
  the deferred `release` runs even when the chain throws, so
  transport errors no longer leak tokens. Two unit tests cover the
  pass-through forwarding and the acquire-mid-chain / release-after
  observation.
- `ConcurrencyTokenBucket` — bounded counting-semaphore actor for
  capping in-flight requests. FIFO fairness queue, never
  over-releases past `maxConcurrent`, clamps the cap to ≥1.
  Adopters can use it directly for custom scheduling, or register
  `ConcurrencyLimitExecutionPolicy` when the limit should run inside
  the request-executor chain. Five unit tests cover
  acquire-under-capacity, release-refill, bounded-release, FIFO waiter
  resume, and cap clamping.
- Five 5.0 forward-compat configuration packs:
  - `ResiliencePack` (retry, coalescing, circuit breaker,
    idempotency, body buffering)
  - `AuthPack` (refresh token, additional signing interceptors)
  - `ObservabilityPack` (event observers, delivery policy, metrics
    reporters, network monitor)
  - `CachePack` (response cache policy, cache backend, failure-
    payload capture)
  - `TransportPack` (timeout, cache policy, request priority,
    cellular/expensive/constrained access toggles, redirect policy,
    `URLSessionConfiguration` override, insecure-HTTP escape)
  Each pack exposes `apply(to: inout NetworkConfiguration.AdvancedBuilder)`
  so adopters can compose the builder additively today; nil pack
  fields leave the builder untouched. The 5.0 release will accept
  the same packs as named init arguments. Pack APIs stay
  source-compatible across 4.x → 5.x; field additions remain
  non-breaking because every property defaults to `nil`.
- 5.0 platform floors backported to iOS 16 / macOS 14 / tvOS 16 /
  watchOS 9 / visionOS 1 (down from the stale draft baseline of iOS 18 /
  macOS 15 / tvOS 18 / watchOS 11 / visionOS 2). The audit confirmed
  no iOS 17+ / macOS 15+ Required Reason or strict-concurrency
  feature is on the public API surface; the only platform-pinned
  dependency is `NWPathMonitor.Sendable` which forces macOS 14+.
  Apps targeting iOS 16+ can now adopt InnoNetwork without an
  OS bump, opening B2C deployment paths that were previously blocked.
- `Sources/InnoNetwork/RequestExecutor.swift` shrinks to ~286 lines
  (down from ~1,045 at the start of Phase 3) by extracting the
  transport stage (`performTransport`, `executeCustomPolicies`,
  `refreshLaneIfInProgress`, `performTransportResult`,
  `transportAndRecordCircuit`, `transport`, `inlineData`,
  `collect`, `mapTransportError`) into
  `Sources/InnoNetwork/RequestExecutor+Transport.swift`. The
  `session` property loses its `private` modifier so the transport
  extension can reach it; consumer-visible surface stays unchanged
  because `RequestExecutor` is `package`-scoped. The central file
  now contains only `execute`, `validateAuthScope`,
  `executeWithPolicies`, and the two `enforceResponseBodyLimit`
  overloads — the request-pipeline core in isolation.
- `Sources/InnoNetwork/RequestExecutor.swift` shrinks again by
  extracting all cache-stage methods (`cachedResponseIfAvailable`,
  `revalidateInBackground`, `prepareConditionalCacheHeaders`,
  `convertNotModifiedIfNeeded`, `refreshCachedFreshness`,
  `mergedCachedHeaders`, `storeCacheIfNeeded`, `cacheControlDirectives`,
  `cachedRespectingVary`) plus the `NotModifiedSubstitution` envelope
  type into `Sources/InnoNetwork/RequestExecutor+Cache.swift`. Three
  call-target helpers (`enforceResponseBodyLimit` overloads,
  `performTransportResult`, `mapTransportError`) lose their `private`
  modifier so the cache extension can reach them through the
  package-internal access level; nothing crosses the public boundary
  because `RequestExecutor` itself is `package`-scoped. The central
  pipeline file drops from ~1,045 to ~602 lines.
- `Sources/InnoNetwork/RequestExecutor.swift` shrinks further by
  extracting the three event publication helpers
  (`notifyRequestStart`, `notifyRequestAdapted`, `notifyFailure`)
  into `Sources/InnoNetwork/RequestExecutor+Events.swift` as a
  package-internal extension. The helpers were `private` and
  consumed only the executor's `eventHub` property; promoting
  `eventHub` from `private` to package-default visibility (still
  invisible to consumers because the parent type is
  `package struct RequestExecutor`) lets the extension call the
  same publication shims without changing the call sites in the
  central pipeline. Symbol surface is unchanged because none of
  these declarations cross the public boundary.
- `Sources/InnoNetwork/RequestExecutor.swift` (1,093 lines) shrinks
  by extracting the internal `BufferedAsyncBytes` AsyncSequence wrapper
  into its own file (`Sources/InnoNetwork/BufferedAsyncBytes.swift`).
  The wrapper is referenced by both `RequestExecutor` (response-body
  buffering) and the test target (chunk-size and max-bytes coverage),
  so the dedicated file keeps the responsibility self-documenting and
  trims the executor file to ~1,045 lines. A deeper executor-stage
  split is intentionally deferred to a follow-up PR because it
  requires reclassifying private members across new extension files
  and is high-risk for the central request pipeline.
- `Sources/InnoNetwork/URLQueryEncoder.swift` (803 lines, single file)
  is split into three files: `URLQueryEncoder.swift` keeps the public
  encoder type plus the `URLQueryArrayEncodingStrategy` /
  `URLQueryFloatEncodingStrategy` enums (167 lines);
  `URLQueryEncoder+Storage.swift` carries the internal
  `_URLQueryEncodingOptions`, `QueryValue`, `QueryValueBox`, and
  `SnakeCaseKeyTransformCache` types; and
  `URLQueryEncoder+Codable.swift` carries the
  `_URLQueryValueEncoder` driver, the keyed/unkeyed/single-value
  containers, and the `encodeQueryValue` dispatch helper. The split
  required promoting four internal `private` types and several helper
  functions to file-internal (default `internal` access) so the
  containers can reach the encoder options across files; symbol
  surface is unchanged because none of these types are public. No
  public API change.
- `Sources/InnoNetwork/HTTPHeader.swift` (642 lines, single file) is
  split into four files for review legibility, no public API change:
  `HTTPHeaders.swift` (collection type and protocol conformances —
  `Sequence`, `Collection`, `ExpressibleByArrayLiteral`,
  `ExpressibleByDictionaryLiteral`, `CustomStringConvertible`),
  `HTTPHeader.swift` (single-pair struct plus `accept(_:)` /
  `authorization(_:)` / `userAgent(_:)` / etc. well-known factories),
  `HTTPHeader+Defaults.swift` (`HTTPHeaders.default`,
  `defaultAcceptEncoding`, `defaultAcceptLanguage`, `defaultUserAgent`,
  and the `qualityEncoded()` helper), and `HTTPHeader+SystemTypes.swift`
  (`URLRequest.headers`, `HTTPURLResponse.headers`,
  `URLSessionConfiguration.headers`, single-value request header
  enforcement). Symbol surface is byte-identical; only file boundaries
  change.
- `Scripts/api_public_symbols.allowlist` (1,123 lines, single file) is
  split into `Scripts/symbols/{core,download,websocket,cache,
  testsupport}.allowlist`, one file per shipping module. The legacy
  single file is removed and `Scripts/check_docs_contract_sync.sh`
  concatenates the per-module files into a temporary allowlist before
  diffing — the validation logic and the entries themselves are
  unchanged. This keeps PR diffs against module symbol changes
  readable: editing the WebSocket allowlist only touches
  `Scripts/symbols/websocket.allowlist` instead of burying the change
  in the middle of an 1,100-line file. Each split file carries a
  header comment that documents the module-scope invariant and the
  expected `<module>\t<kind>\t<declaration>` format.

### Documentation

- `docs/Cookies.md` documents per-client cookie storage isolation
  through `urlSessionConfigurationOverride`. Covers the multi-account
  registry pattern, cookie-free SDK clients, and a verification recipe.
  The hook itself was already public; the doc closes the discoverability
  gap and the `urlSessionConfigurationOverride` doc comment now points
  callers at the recipe.
- `docs/HTTP3.md` documents how to opt into HTTP/3 (QUIC) by setting
  `assumesHTTP3Capable = true` through the same
  `urlSessionConfigurationOverride` hook, plus the compatibility
  matrix, when-to-enable checklist, verification recipe via
  `URLSessionTaskMetrics.networkProtocolName`, and the QUIC-specific
  caveats (captive portals, background sessions, 0-RTT idempotency).
  The runtime surface stays unchanged.
- `docs/AppGroupSharedSession.md` covers App Group / extension
  scenarios: Pattern A wires a fully isolated extension client (cookie
  jar scoped to the extension's group container), Pattern B reuses a
  background `sessionIdentifier` across host app and extension to keep
  a single OS-managed download queue. The article also explicitly
  flags `URLSessionConfiguration.background(...).sharedContainerIdentifier`
  as a known gap on `DownloadConfiguration` (currently treated as an
  implementation detail) and recommends Pattern A as the default
  pending the follow-up that exposes the knob.
- `Benchmarks/README.md` documents the explicit baseline-update protocol:
  how to re-measure on the hosted runner, replace
  `Benchmarks/Baselines/default.json`, log the change in
  `Benchmarks/Baselines/CHANGELOG.md`, and what counts as a "meaningful"
  regression worth refreshing the baseline for. The dedicated `Benchmarks`
  workflow owns guarded regression enforcement; the CI benchmark smoke job
  only proves the benchmark CLI still builds and emits parseable JSON.

## [4.0.0] - 2026-05-02

InnoNetwork's first public release. The detailed 4.0.0 changelog has
been archived to [`docs/releases/4.0.0.md`](docs/releases/4.0.0.md) —
that document carries the curated release notes (originally a
one-pager) together with the full per-line CHANGELOG section that
previously lived here, plus the 49-item hardening coverage table and
release-quality matrix. The migration guide at
[`docs/Migration-4.0.0.md`](docs/Migration-4.0.0.md) remains the entry
point for upgrade work.

This `CHANGELOG.md` retains only the `Unreleased` window and the
archive pointers below; older releases (when they exist) follow the
same pattern.

### Older releases

Per-version detail is captured under [`docs/releases/`](docs/releases/).
The current archive is [`4.0.0.md`](docs/releases/4.0.0.md).
