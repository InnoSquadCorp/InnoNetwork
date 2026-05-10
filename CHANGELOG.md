# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and the project follows Semantic
Versioning.

## [Unreleased]

### Added

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

### Removed

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
  the matching field on `AdvancedBuilder`, and the `urlSessionConfigura
  tionOverride` parameter on `NetworkConfiguration.init(...)` and
  `TransportPack.init(...)` have been removed. The hook was a leaky
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

### Changed

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
  watchOS 9 / visionOS 1 (down from the 4.x baseline of iOS 18 /
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
  regression worth refreshing the baseline for. The benchmark-smoke
  guard (already enforcing `--enforce-baseline --max-regression-percent
  20` on guarded entries) stays the runtime gate; the README addition
  removes the recurring ambiguity around when and how operators should
  refresh the file.

## [4.0.0] - 2026-05-02

InnoNetwork's first public release. The package targets Apple platforms only
and is built around Swift Concurrency, explicit transport policies, and
operational visibility from prototype to production. See
[`docs/releases/4.0.0.md`](docs/releases/4.0.0.md) for the one-page release
summary and [`docs/Migration-4.0.0.md`](docs/Migration-4.0.0.md) for migration
guidance.

### 49-Item Hardening Summary

This release folds the full 49-item hardening pass into the public 4.0.0
baseline instead of shipping it as a follow-up patch. The review severity
distribution was 1 Critical, 17 High, 23 Medium, and 8 Low items. Breaking
changes are intentional and are called out below; migration recipes live in
[`docs/Migration-4.0.0.md`](docs/Migration-4.0.0.md).

| Area | Hardening IDs |
| --- | --- |
| Security / privacy | 1-1, 1-2, 1-5, 2-12, 3-2, 3-4, 3-20, 3-22 |
| Memory / lifecycle / concurrency | 1-3, 1-4, 2-1, 2-7, 2-15, 2-16, 3-9, 3-14 |
| Data integrity / retry / cache correctness | 2-2, 2-3, 2-5, 2-13, 2-17, 2-18, 3-1, 3-3, 3-6, 3-15 |
| HTTP standards | 2-21, 3-5, 3-11, 3-12 |
| Performance hot paths | 2-4, 2-6, 2-9, 2-10, 2-11, 2-14, 2-22, 3-7, 3-13, 3-18 |
| API / naming cleanup | 2-8, 2-19, 2-20, 3-17, 3-19 |
| Test infrastructure | 3-8, 3-10, 3-21 |
| CI / supply chain | 3-16 |

### Hardening Pass — Breaking

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
  `NetworkError.configuration(reason: .invalidRequest(...))` instead of
  returning an empty array.
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
- `Endpoint<Response>` and `AuthenticatedEndpoint<Response>` fluent aliases
  are removed. Use `EndpointBuilder<Response, PublicAuthScope>` or
  `EndpointBuilder<Response, AuthRequiredScope>` explicitly.
- `WebSocketManager.shared` is removed. Construct and inject a
  feature-owned `WebSocketManager(configuration:)`.

### Hardening Pass — Added

- `NetworkConfiguration.urlSessionConfigurationOverride` and
  `NetworkConfiguration.makeURLSessionConfiguration()` provide an escape
  hatch for proxy/HTTP2/connection-pool/TLS tuning without forking the
  abstraction.
- `NetworkConfiguration.redirectPolicy` defaults to
  `DefaultRedirectPolicy`, which strips `Authorization`, `Cookie`, and
  `Proxy-Authorization` on cross-origin redirects.
- `NetworkConfiguration.allowsInsecureHTTP` defaults to `false`; plain
  `http://` base URLs fail during request construction unless a client
  explicitly opts in for a local/dev endpoint.
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
- Supply-chain CI: Dependabot now watches SwiftPM and GitHub Actions, every
  workflow action is pinned to a full commit SHA, and CI runs
  `actions/dependency-review-action` on pull requests.
- `NetworkError.errorDescription` now resolves through bundled English and
  Korean localization catalogues while preserving the existing English
  fallback strings.
- DocC includes a "Build a GitHub Client" tutorial that walks from
  `APIDefinition` modeling to `DefaultNetworkClient.request(_:)`.
- Benchmarks now report process resident memory snapshots alongside
  throughput. Memory metrics are observational only in 4.0.0 and are not
  part of the regression guard threshold.

### Hardening Pass — Fixed

- Redirect handling no longer leaks credential-bearing headers across
  origins, and base URLs containing embedded `user:password@` credentials
  or fragments fail before transport dispatch.
- `Cache-Control` parsing is quoted-string aware. Directives such as
  `private="Set-Cookie, Authorization"` now still count as `private`,
  invalidating the current cache key and skipping storage.
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
- `AuthScope`, `PublicAuthScope`, `AuthRequiredScope`, and
  `EndpointBuilder` for type-level auth
  boundaries. Auth-required endpoints fail before transport when no
  `RefreshTokenPolicy` is configured.
- `StateReducer` and `StateReduction` as the shared reducer vocabulary for
  lifecycle state machines.
- `InnoNetworkPersistentCache` product with `PersistentResponseCache` and
  `PersistentResponseCacheConfiguration` for conservative on-disk GET
  response caching.
- `PersistentResponseCache` format v2 protects sensitive cache-key header
  components with managed HMAC-SHA256, exposes an App Group directory helper,
  self-heals from corrupt or unknown-version on-disk indexes by resetting the
  cache's own subtree, and surfaces statistics plus scrub/eviction telemetry
  for production operations.
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
- `MultipartStreamingResponseDecoder` and `MultipartStreamingEvent` for
  large or long-lived multipart response streams. The streaming parser emits
  `partStarted`, `bodyChunk`, and `partEnded` events while preserving
  boundary-like payload bytes.
- `InnoNetworkOpenAPI` companion product with `OpenAPIRestOperation` and
  `OpenAPIRequest`, allowing generated or hand-written OpenAPI operation
  descriptors to run through `NetworkClient` without adding dependencies to
  the core runtime products.
- VCR-style `InnoNetworkTestSupport` helpers (`VCRURLSession`,
  `VCRCassette`, `VCRRequest`, `VCRResponse`, and redaction policy types) for
  deterministic record/replay tests with credential/query redaction and
  unmatched-request failures.
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
- `WebSocketManager.shutdown() async` as the canonical WebSocket lifecycle
  teardown. Shutdown is idempotent, terminal, cancels active runtime tasks,
  finishes event streams, clears listeners, and waits for URLSession
  invalidation before returning.
- `WebSocketError.unsupportedProtocolFeature` and `WebSocketProtocolFeature`
  for explicit protocol-negotiation diagnostics. The URLSession transport now
  rejects `permessageDeflateEnabled` instead of silently opening an
  uncompressed socket.
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
- Benchmark JSON summary version 2 includes baseline deltas, guarded
  benchmark failures, per-benchmark thresholds, and optional regression
  rationale. The benchmark workflow renders a PR comment and appends
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
- `EndpointBuilder` replaces `.contentType(_:)` with `.transport(_:)`. The
  `Content-Type` header is derived from the transport's request encoding,
  and `decoding(_:)` carries the request encoding into the new response
  generic instead of resetting it.
- Fluent endpoint aliases are removed. Use
  `EndpointBuilder<Response, PublicAuthScope>` for public fluent endpoints and
  `EndpointBuilder<Response, AuthRequiredScope>` for auth-required fluent
  endpoints.
- `WebSocketManager.shared` has been removed. Construct
  `WebSocketManager(configuration:)` per feature.
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
  `associatedtype Auth: AuthScope = PublicAuthScope`, so a multipart
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
