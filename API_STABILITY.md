# API Stability

This document defines the compatibility contract for the InnoNetwork 4.x
release line. `4.0.0` is the public baseline for this contract.

## Stable

- `APIDefinition`
- `CancellationTag`
- `Endpoint`
- `MultipartAPIDefinition`
- `TransportPolicy`
- `RequestEncodingPolicy`
- `ResponseDecodingStrategy`
- `DefaultNetworkClient`
- `DefaultNetworkClient.shutdown()`
- `NetworkClient.request(_:)`
- `NetworkClient.request(_:tag:)`
- `NetworkClient.request(_:method:tag:)`
- `NetworkClient.upload(_:)`
- `NetworkClient.upload(_:tag:)`
- `NetworkConfiguration.safeDefaults(baseURL:)`
- `NetworkConfiguration.advanced(baseURL:resilience:auth:observability:cache:transport:)`
- `DownloadConfiguration.safeDefaults()`
- `DownloadConfiguration.advanced(_:)`
- `WebSocketConfiguration.safeDefaults()`
- `WebSocketConfiguration.advanced(_:)`
- `WebSocketHandshakeRequestAdapter`
- `DownloadManager`
- `WebSocketManager`
- `WebSocketManager.shutdown()`
- `WebSocketEvent.ping`
- `WebSocketEvent.pong`
- `WebSocketEvent.error(.pingTimeout)`
- `WebSocketPingContext`
- `WebSocketPongContext`
- `TrustPolicy`
- `TrustChallengeOutcome`
- `PublicKeyPinningPolicy`
- `PublicKeyPinningPolicy.HostMatchingStrategy`
- `PublicKeyPinningEvaluator`
- `AnyResponseDecoder`
- `URLQueryEncoder`
- `URLQueryArrayEncodingStrategy`
- `ResponseBodyBufferingPolicy`
- `RequestExecutionPolicy`
- `NetworkErrorCategory`
- `NetworkError.category`
- `NetworkError.isRetriableHint`
- `NetworkError.isUserVisible`
- `AuthScope`
- `PublicAuthScope`
- `AuthRequiredScope`
- `StateReducer`
- `EventDeliveryPolicy`
- `WebSocketCloseCode`
- `EndpointBuilder`, `EndpointPathEncoding` (promoted from Provisionally Stable in 4.x.x; the path-encoding shape and decoding helpers are SemVer-protected)
- `DecodingInterceptor` (promoted from Provisionally Stable in 4.x.x)
- `WebSocketCloseDisposition` (promoted from Provisionally Stable in 4.x.x)

> **No 5.0 major bump is planned in the 4.x line.** The Stable
> ledger only grows over the rest of 4.x; entries do not move
> back into Provisionally Stable. Surfaces that need a breaking
> change wait until a future major. Adopters can pin
> `.upToNextMajor(from: "4.0.0")` and rely on the entries above
> remaining source-compatible across the entire 4.x line.

## Stable Examples

A subset of `Examples/` participates in the SemVer-protected stable
contract. For each entry below the directory must exist, contain at least
one Swift source file, ship a `README.md`, and compile against the current
public package. The exact wording of the example is **not** contractual, but
the copyable Swift starting points must stay source-compatible with the
4.0.0 public API.
The `Scripts/check_stable_examples.sh` gate, wired into the docs-contract
job, fails CI if a stable example is removed, emptied, loses its README, or
stops compiling. The smoke build runs with Swift warnings treated as errors
because these examples are copyable public-contract code, not narrative-only
documentation.

- `Examples/BasicRequest` — request/response fundamentals across HTTP verbs
  and content types.
- `Examples/Auth` — `RefreshTokenPolicy` wiring with a Keychain-backed
  token store and single-flight refresh.
- `Examples/ErrorHandling` — `NetworkError` taxonomy and the
  `do`/`catch` patterns that surface response payloads.

Every other example (`DownloadManager`, `WebSocketChat`,
`EventPolicyObserver`, the consumer smoke packages, …) stays
Provisionally Stable: structure may evolve across minors and they are
intentionally **not** enforced by the gate above. README/DocC examples
continue to track the stable APIs they illustrate; their wording is not
part of the compatibility contract.

## Provisionally Stable

Symbols in this section are public and supported, but they may grow new
cases, parameters, or shape during the 4.x line. Each change ships with
release notes describing the migration path. Consumers who want strict
compile-time stability should pin the package with
`.upToNextMinor(from: "4.0.0")` (see "Version Pinning Guidance" below)
and treat any 4.y → 4.(y+1) bump as a code-level review boundary.

- `default` aliases on configuration types
- benchmark runner CLI flags and JSON summary presentation details
- troubleshooting guidance and examples in README/DocC
- `InnoNetworkTestSupport` library product and its `public` symbols
  (currently `MockURLSession`, `MockURLSessionResponse`,
  `WebSocketEventRecorder`, `StubBehavior`, `StubNetworkClient`, and
  `StubRequestKey`)
- `AnyEncodable`, `NetworkContext`, and `CorrelationIDInterceptor`
- `RefreshTokenPolicy`, `RequestCoalescingPolicy`, retry, response cache, redirect, encoding utility, and circuit breaker policy surfaces
- `MultipartResponseDecoder` buffered multipart response parsing surface
- `MultipartStreamingResponseDecoder` streaming multipart response parsing surface
- `InnoNetworkOpenAPI` companion product
- `InnoNetworkCodegen` separate package and macro declarations
- `PersistentResponseCache` statistics and telemetry surfaces
- `WebSocketError.unsupportedProtocolFeature`
- `WebSocketProtocolFeature`
- `JWTBearerInterceptor` reference signer for request-minted JWT bearer tokens
- `InnoNetworkAuthAWS` companion product and `AWSSigV4Interceptor` reference signer for single-shot AWS SigV4 signing
- `StreamingBufferingPolicy`, `TraceContextInterceptor`, `W3CTraceContext`, `CurlCommandOptions`, `IdempotencyKeyPolicy`, `RequestPriority`, and `NetworkConfiguration.recommendedForProduction(baseURL:)`
- `NetworkConfiguration.with(retry:)` / `with(cache:)` / `with(circuitBreaker:)` / `with(refresh:)` / `with(coalescing:)` / `with(executionPolicies:)` / `with(eventObservers:)` fluent modifier surface
- `HTTPHeaderName<Variant>` phantom-typed header key surface and its predefined `SingleValueHeader` / `RepeatableHeader` markers (also referenced as `HTTPHeaderName` / `HTTPHeaderVariant` for contract-sync purposes)
- `MultipartUploadStrategy.threshold(bytes:)`
- `StreamingResumeStrategy` protocol and the `isCompatible(with:)` requirement; `StreamingResumePolicy` retroactive conformance
- `PersistentResponseCacheStatistics.hitCount` / `missCount` / `evictionCount`
- `DownloadTask.generation` / `attempt` observation accessors
- `NetworkErrorCode` SSOT enum (4.1.0) — owns every `NetworkError.errorCode` raw value; new cases may be added in 4.x minors when `NetworkError` itself adds a case
- `NetworkError.reachability(_:_:_:)` and `ReachabilityReason` (4.1.0)
- `MultipartUploadStrategy.inMemory(maxBytes:)` (4.1.0) — replaces the zero-arg `.inMemory` form (4.0.x); the encoder's accumulator guard is part of the contract
- `DownloadConfiguration.taskInactivityTimeout` and `DownloadTask.lastProgressAt` (4.1.0)
- `ResponseCachePolicy.rfc9111Compliant(wrapping:)` directive-aware adapter (4.1.0)
- `DownloadConfiguration.sharedContainerIdentifier` and `DownloadConfiguration.AdvancedBuilder.sharedContainerIdentifier` (4.1.0)
- `ResponseCache.invalidateTargetURI(_:)` and RFC 9111 unsafe-method target URI invalidation (4.1.0)
- `NetworkConfiguration.streamingLineByteLimit` and `TransportPack.streamingLineByteLimit` (4.1.0)

## Provisionally Stable Evolution Boundaries

Per-symbol evolution allowances within the 4.x line:

Promotion from Provisionally Stable to Stable requires all of the following:

- The symbol has DocC or README coverage for the intended stable usage.
- Contract tests or smoke examples exercise the source shape that is being
  promoted.
- The CHANGELOG and migration notes describe the promotion and any required
  adopter action.
- Stable examples or generated-client recipes are updated when the promoted
  surface is a recommended entry point.
- The symbol is moved into the Stable ledger above; once promoted, it cannot
  move back to Provisionally Stable within the 4.x line.

| Surface | Promotion target | Required evidence |
| --- | --- | --- |
| `EndpointBuilder` onboarding path | Stable at 4.0.0 | README first-30-minute flow, stable example smoke, and migration cookbook examples compile. |
| `InnoNetworkAuthAWS` | 4.x minor after adopter validation | AWS SigV4 vector tests, product README/DocC scope, and explicit "reference signer, not AWS SDK replacement" wording. |
| `PersistentResponseCache` statistics and telemetry | 4.x minor | Reentrancy invariant docs plus persistent cache key-rotation/statistics tests. |
| `ResponseCachePolicy.rfc9111Compliant(wrapping:)` | 4.x minor | The subset is documented as RFC 9111-aware, with directive tests for the supported rules. |
| `InnoNetworkCodegen` macros | No automatic promotion | Promote only if the before/after ROI is clear; otherwise keep provisional or deprecate. |

- `default` aliases — may add new defaults; never removed within 4.x.
- Benchmark runner CLI flags and JSON keys — may evolve to reflect new
  metrics; baseline contents are operational policy.
- README/DocC examples — track the stable APIs they illustrate; their
  exact wording is not part of the compatibility contract.
- `InnoNetworkTestSupport` — additional helpers may be added; existing
  symbols stay source-compatible within 4.x. VCR-style cassette helpers are
  intended for test targets and may gain new matching/redaction knobs.
- `EndpointBuilder`, `AnyEncodable`, `NetworkContext`, `CorrelationIDInterceptor` —
  builder shape may grow new chainable methods.
- `EndpointPathEncoding` — may add new helpers for placeholder encoding;
  existing entry points remain source-compatible. The set of percent-encoded
  characters tracks RFC 3986 reserved/unreserved updates and may widen
  encoding for newly disallowed scalars without prior deprecation.
- `URLQueryEncoder` — the default array convention remains indexed brackets
  for 4.0.0 compatibility, while ``URLQueryArrayEncodingStrategy`` can opt in
  to bracketed or repeated-key arrays per provider.
- `ResponseBodyBufferingPolicy` — the default inline request path is
  streaming, with `responseBodyLimit` retained as a source-compatible alias
  for the policy's `maxBytes` value.
- `NetworkConfiguration.streamingLineByteLimit` — controls the maximum UTF-8
  byte length for one line-delimited streaming frame. The default remains
  `NetworkConfiguration.defaultStreamingLineByteLimit` (1 MiB), and values
  below 1 are normalized to 1.
- `RequestExecutionPolicy` — custom policies may wrap raw transport attempts;
  built-in retry, refresh, cache, coalescing, and circuit breaker behavior
  remains provided by `NetworkConfiguration`.
- `AuthScope` — marker scopes can be added in future minors; the
  public/auth-required split remains source-compatible for 4.0.0.
- `MultipartAPIDefinition.Auth` — the multipart protocol carries the same
  `Auth: AuthScope` associated type as `APIDefinition`, defaulted to
  `PublicAuthScope`. Existing multipart endpoints stay source-compatible;
  authenticated multipart uploads must declare `typealias Auth = AuthRequiredScope`
  to participate in `RefreshTokenPolicy` validation.
- `StateReducer` — public reducer vocabulary for lifecycle state machines;
  package products can use it for internal reducers while keeping effect
  execution owned by their managers.
- `WebSocketCloseDisposition` — additional enum cases may appear as new
  close-code classifications are formalized.
- `RefreshTokenPolicy`, `RequestCoalescingPolicy`, retry, response cache,
  redirect, encoding utility, and circuit breaker policy — built-in knobs may
  add fields, helper cases, or sensitive-header defaults with
  source-compatible behavior; the generic execution pipeline stays
  package/internal. Retry defaults treat `GET`, `HEAD`, `OPTIONS`, and
  `TRACE` as safe, while `PUT` and `DELETE` require `Idempotency-Key` or an
  explicit method-agnostic policy. Response cache writes for requests carrying
  `Authorization` require both the caller's privacy opt-in and an RFC 9111
  permission directive (`public`, `must-revalidate`, or `s-maxage`).
- `NetworkConfigurationFailureReason` — typed payload for
  ``NetworkError/configuration(reason:)``. Carries
  `invalidBaseURL` / `invalidRequest` / `offline` cases. The standalone
  `NetworkError.invalidBaseURL` and
  `NetworkError.invalidRequestConfiguration` cases are not part of the
  4.0.0 surface; adopters switch on this reason payload directly.
- `ReachabilityCheckExecutionPolicy` — `RequestExecutionPolicy` that
  consults a `NetworkMonitoring` source and short-circuits requests
  when the path is `.unsatisfied`. `.requiresConnection` waits up to
  `suspensionWaitTimeout` before forwarding, surfacing offline, or
  throwing ``NetworkError/transportSuspended``; unobserved snapshots fall
  through. Offline rejections surface as
  ``NetworkError/configuration(reason:)`` with
  ``NetworkConfigurationFailureReason/offline(_:)``.
- `ConcurrencyLimitExecutionPolicy` — `RequestExecutionPolicy` that
  funnels each transport attempt through a `ConcurrencyTokenBucket`
  with cancellation-aware `acquire` / awaited `release` semantics.
  Registered via `ResiliencePack.customExecutionPolicies`. Surface stays
  source-compatible across the planned 5.x bucket integration that may
  move the policy into a built-in pre-flight stage.
- `ConcurrencyTokenBucket` — bounded counting semaphore actor for
  capping in-flight work. Raw bucket users can still protect custom
  async work directly, but request execution paths should prefer
  `ConcurrencyLimitExecutionPolicy` over paired
  `RequestInterceptor` / `ResponseInterceptor` wiring because the policy
  owns release on success, failure, and cancellation. `acquire()` is
  `async throws` in 4.1.0 so queued cancellation removes the waiter
  before a future token can be consumed; direct callers must use
  `try await`.
- `ResiliencePack`, `AuthPack`, `ObservabilityPack`, `CachePack`,
  `TransportPack` — configuration packs accepted as named arguments by
  `NetworkConfiguration.advanced(baseURL:resilience:auth:observability:cache:transport:)`.
  Each pack groups a thematic axis of options; the underlying builder
  is now `package`-only. The pack APIs stay source-compatible from
  4.x → 5.x; future minors may add fields to existing packs without
  breaking call sites because every field defaults to `nil`.
- `HMACRequestInterceptor` — reference HMAC body-signing interceptor
  (SHA-256 / SHA-384 / SHA-512). Header names and key id are
  provider-tunable; the streaming-body rejection is intentional, and
  future minors may add a streaming-aware integration without breaking
  source compatibility for the existing initializer signature.
- `MultipartResponseDecoder` and `MultipartStreamingResponseDecoder` — the
  buffered API remains source-compatible; the streaming event vocabulary may
  gain additive diagnostic events as more long-lived multipart deployments are
  exercised.
- `InnoNetworkOpenAPI` — adapter protocols may add optional requirements with
  default implementations to track Swift OpenAPI Generator and HTTPTypes
  conventions without pulling those packages into the core runtime.
- `PersistentResponseCache` statistics and telemetry — event reasons may grow
  as additional scrub cases are surfaced.
- `ResponseCache.invalidateTargetURI(_:)` — the protocol requirement has a
  default implementation for source compatibility; built-in caches remove all
  variants for the normalized target URI, while custom caches may override the
  default to match their own key layout.
- `ResponseCachePolicy.rfc9111Compliant(wrapping:)` — the adapter may tighten
  read-side freshness handling as RFC 9111 coverage expands. `max-age`
  remains higher priority than `Expires`, which remains higher priority than
  the `Last-Modified` heuristic; invalid or duplicate freshness directives
  are treated as stale rather than extending cache reuse.
- `NetworkErrorCode` — raw values use the
  `com.innosquad.innonetwork.NetworkError` domain exclusively; Foundation
  `URLError` codes are preserved only as underlying metadata.
- `WebSocketError.unsupportedProtocolFeature` and `WebSocketProtocolFeature`
  — feature cases may grow as optional transports add or reject more protocol
  extensions.
- `InnoNetworkCodegen` — macro signatures may add optional arguments.
- `DecodingInterceptor` — protocol may grow new optional hooks with
  default implementations as additional decode-boundary use cases
  surface.
- `StreamingBufferingPolicy` — bounded buffering cases may gain additional
  policy knobs, but `stream(_:)` stays lossless by default for 4.x and bounded
  buffers remain incompatible with `StreamingResumePolicy.lastEventID`.
- `TraceContextInterceptor` and `W3CTraceContext` — W3C header propagation
  remains additive; future minors may add richer correlation helpers without
  changing `NetworkEvent` case shape.
- `CurlCommandOptions` — the default redaction list may expand as additional
  sensitive headers become common; callers can still provide an explicit set.
- `IdempotencyKeyPolicy` — retry attempts reuse one request-scoped key for
  unsafe methods; future minors may add provider hooks without changing the
  request-ID invariant.
- `RequestPriority` and network-condition request controls — additional
  platform mappings may be added while preserving current defaults.
- `NetworkConfiguration.recommendedForProduction(baseURL:)` — the preset may
  tune default policy values in minors, but it remains a convenience builder
  over documented public policies. 4.1.0 caps streaming response body
  collection at 5 MiB by default.
- `NetworkConfiguration.init(...)` — the direct 32-parameter public
  construction surface was removed before the 4.0.0 baseline and is not part
  of the 4.x stable API. Use presets, configuration packs, and fluent
  modifiers instead.
- `DownloadConfiguration.sharedContainerIdentifier` — additive App Group
  background-session storage knob. Default stays `nil`; future minors may add
  preset helpers, but the property and builder field remain source-compatible.
- `HTTPHeader`, `HTTPHeaders`, and default header providers — default
  `User-Agent` / `Accept-Language` values are evaluated at request-build time
  so applications can inject bundle or locale ownership without relying on a
  process-start snapshot.

## Version Pinning Guidance

Apps that consume InnoNetwork via SwiftPM should pin against the 4.0.0 minor:

```swift
.package(url: "https://github.com/InnoSquadCorp/InnoNetwork", .upToNextMinor(from: "4.0.0"))
```

`.upToNextMinor(from:)` accepts patch upgrades within the pinned minor
but requires an explicit bump to consume the next minor. This matches
the stability contract: stable surfaces follow SemVer, but provisionally
stable surfaces may add or evolve in a minor bump, so consumers should
review the changelog for the minor before adopting.

Use `.upToNextMajor(from:)` only if you exclusively call the **Stable**
ledger and accept that provisionally stable APIs may shift under you on
minor releases.

## Public Declaration Ledger

The docs-contract gate extracts public symbols from Swift symbol graphs and
compares them with `Scripts/symbols/*.allowlist`. That catches nested public
types and members in addition to top-level declarations. The grouped ledger
below keeps the high-level compatibility classification readable for the 4.x
release line.

### InnoNetwork

- `APIDefinition`, `AnyEncodable`, `AnyRequestExecutionPolicy`,
  `AnyResponseDecoder`, `AuthRequiredScope`,
  `CachedResponse`, `CacheRevalidationState`, `CancellationTag`,
  `CircuitBreakerOpenError`, `CircuitBreakerPolicy`,
  `ContentType`, `CorrelationIDInterceptor`, `CurlCommandOptions`,
  `DecodingStage`,
  `DefaultNetworkClient`, `DefaultRedirectPolicy`,
  `DefaultNetworkLogger`, `EmptyParameter`, `EmptyResponse`,
  `AuthScope`, `EndpointPathEncoding`, `Endpoint`,
  `HTTPEmptyResponseDecodable`, `HTTPHeader`, `HTTPHeaders`, `HTTPMethod`,
  `IdempotencyKeyPolicy`, `InMemoryResponseCache`, `MultipartAPIDefinition`, `MultipartFormData`,
  `MultipartPart`, `MultipartResponseDecoder`,
  `MultipartStreamingEvent`, `MultipartStreamingResponseDecoder`,
  `MultipartUploadStrategy`,
  `NetworkClient`, `NetworkConfiguration`, `NetworkContext`, `NetworkError`,
  `NetworkErrorCategory`,
  `NetworkEvent`, `NetworkEventObserving`, `NetworkInterfaceType`,
  `NetworkLoggingOptions`, `NetworkLogger`, `NetworkMetricsReporting`,
  `NetworkMonitor`, `NetworkMonitoring`, `NetworkReachabilityStatus`,
  `NetworkRequestContext`, `NetworkSnapshot`, `NoOpNetworkEventObserver`,
  `NoOpNetworkLogger`, `OSLogNetworkEventObserver`, `PublicAuthScope`,
  `RedirectPolicy`, `RefreshFailureCooldown`, `RefreshTokenPolicy`,
  `RequestCoalescingPolicy`, `RequestEncodingPolicy`,
  `RequestPriority`,
  `RequestInterceptor`, `Response`, `ResponseCache`, `ResponseCacheKey`,
  `RequestExecutionContext`, `RequestExecutionInput`, `RequestExecutionNext`,
  `RequestExecutionPolicy`, `ResponseBodyBufferingPolicy`,
  `ResponseCacheHeaderPolicy`, `ResponseCachePolicy`,
  `ResponseDecodingStrategy`, `ResponseInterceptor`,
  `RetryDecision`, `RetryIdempotencyPolicy`, `RetryPolicy`,
  `RFC3986Encoding`, `EndpointBuilder`, `SendableUnderlyingError`, `ServerSentEvent`,
  `ServerSentEventDecoder`, `StateReducer`, `StateReduction`,
  `StreamingAPIDefinition`, `StreamingBufferingPolicy`,
  `StreamingResumePolicy`, `TimeoutReason`, `TraceContextInterceptor`,
  `TransportPolicy`, `TrustChallengeOutcome`, `TrustEvaluating`, `TrustFailureReason`, `TrustPolicy`,
  `URLQueryArrayEncodingStrategy`, `URLQueryCustomKeyTransform`,
  `URLQueryEncoder`, `URLQueryFloatEncodingStrategy`,
  `URLQueryKeyEncodingStrategy`, `URLSessionProtocol`, and
  `W3CTraceContext`.
- Event-pipeline observability declarations: `EventDeliveryPolicy`,
  `EventPipelineAggregateSnapshotMetric`,
  `EventPipelineConsumerDeliveryLatencyMetric`,
  `EventPipelineConsumerStateMetric`, `EventPipelineHubKind`,
  `EventPipelineMetric`, `EventPipelineMetricsReporting`,
  `EventPipelineOverflowPolicy`, `EventPipelinePartitionStateMetric`,
  `ExponentialBackoffRetryPolicy`, and `NoOpEventPipelineMetricsReporter`.

### InnoNetworkDownload

- `DownloadConfiguration`, `DownloadError`, `DownloadEvent`,
  `DownloadEventSubscription`, `DownloadManager`, `DownloadManagerError`,
  `DownloadProgress`, `DownloadState`, and `DownloadTask`.

### InnoNetworkWebSocket

- `WebSocketCloseCode`, `WebSocketCloseDisposition`, `WebSocketConfiguration`,
  `WebSocketError`, `WebSocketEvent`, `WebSocketEventSubscription`,
  `WebSocketHandshakeRequestAdapter`, `WebSocketManager`,
  `WebSocketPingContext`, `WebSocketPongContext`, `WebSocketProtocolFeature`,
  `WebSocketSendOverflowPolicy`, `WebSocketState`, and `WebSocketTask`.

### InnoNetworkTrust

- `PublicKeyPinningEvaluator`, `PublicKeyPinningPolicy`, and
  `PublicKeyPinningPolicy.HostMatchingStrategy`.

### InnoNetworkAuthAWS

- `AWSSigV4Interceptor`.

### InnoNetworkPersistentCache

- `PersistentResponseCache`, `PersistentResponseCacheConfiguration`,
  `PersistentResponseCacheEvictionReason`, `PersistentResponseCacheStatistics`,
  and `PersistentResponseCacheTelemetryEvent`.

### InnoNetworkOpenAPI

- `OpenAPIRestOperation`, `OpenAPIRequest`, `InnoNetworkClientTransport`,
  and `InnoNetworkClientTransportError`.

### InnoNetworkTestSupport

- `MockURLSession`, `StubBehavior`, `StubNetworkClient`, `StubRequestKey`,
  `MockURLSessionResponse`, `VCRCassette`, `VCRInteraction`, `VCRMode`,
  `VCRRedactionPolicy`, `VCRRequest`, `VCRResponse`, `VCRURLSession`, and
  `WebSocketEventRecorder`.

### InnoNetworkCodegen Package

- `APIDefinition(method:path:)` attached macro.
- `endpoint(_:_:as:)` freestanding expression macro.

Macro expansion is source-generation behavior, not a new runtime public API.
The attached macro emits witnesses at the attached type's visibility
(`public`, `package`, or implicit internal) so generated clients can export
public endpoint types deliberately while app-internal endpoints remain internal.

### SPI

InnoNetwork exposes a small set of execution-pipeline hooks through
`@_spi(GeneratedClientSupport)` for generated clients (for example, OpenAPI
adapters) that need to plug their own serialization and decoding into the
shared retry, refresh, and observability machinery. These symbols are
**best-effort**: they are not part of the default SwiftPM import contract,
they are not ABI-stable across releases, and they may evolve in any minor
release without a deprecation window. Callers must opt in with
`@_spi(GeneratedClientSupport) import InnoNetwork`.

| Symbol | Visibility | Stability |
|---|---|---|
| `LowLevelNetworkClient` | `@_spi(GeneratedClientSupport) public` | Best-effort, no ABI guarantee |
| `DefaultNetworkClient.perform(_:)` | `@_spi(GeneratedClientSupport) public` | Best-effort, no ABI guarantee |
| `DefaultNetworkClient.perform(executable:)` | `@_spi(GeneratedClientSupport) public` | Best-effort, no ABI guarantee |
| `SingleRequestExecutable` | `@_spi(GeneratedClientSupport) public` | Best-effort, no ABI guarantee |
| `APISingleRequestExecutable` | `@_spi(GeneratedClientSupport) public` | Best-effort, no ABI guarantee |
| `MultipartSingleRequestExecutable` | `@_spi(GeneratedClientSupport) public` | Best-effort, no ABI guarantee |
| `RequestPayload` | `@_spi(GeneratedClientSupport) public` | Best-effort, no ABI guarantee |

See `Examples/WrapperSmoke` and `Examples/GeneratedClientRecipe` for the
intended usage shape.

Generated clients should prefer the stable `APIDefinition` wrapper path. The
SPI path is reserved for code generators that own custom serialization or
decoding and can pin an InnoNetwork revision.

#### `@_spi(GeneratedClientSupport)` Compatibility Contract

This subsection is the canonical contract for the
`@_spi(GeneratedClientSupport)` surface. It is referenced from
`Sources/InnoNetwork/InnoNetwork.docc/Articles/GeneratedClientRecipe.md` and
from `Examples/GeneratedClientRecipe` so generated-client authors have a
single entry point for the rules.

**1. SPI may break in any release, including minor releases.**

The symbols listed in the SPI table above sit *outside* the
SemVer contract that governs the `Stable` and `Provisionally Stable`
sections. They may be renamed, resigned, removed, or replaced in any
minor release (for example `5.1 → 5.2`) without a deprecation window
and without a `[Breaking]` callout in `CHANGELOG.md`. SPI changes still
appear in the changelog, but in a dedicated `[SPI]` subsection that
does not require a major version bump.

**2. `InnoNetworkCodegen` is co-updated for every SPI break.**

Whenever an SPI symbol changes shape, the matching
`Packages/InnoNetworkCodegen` macros and recipe templates ship updated
expansions in the **same release** of InnoNetwork. Consumers who use
the macro path (`@APIDefinition(...)` and `endpoint(_:_:as:)`) and pin
both packages to the same InnoNetwork tag therefore never observe an
SPI break — the regenerated witnesses absorb the new shape.

This guarantee is *only* extended to `InnoNetworkCodegen`. Third-party
generators (custom OpenAPI adapters, in-house DSLs, hand-written `@_spi`
imports) must validate their integration against each new InnoNetwork
release.

**3. External `@_spi` imports are opt-in and unsupported.**

Code outside the `InnoNetwork` and `InnoNetworkCodegen` packages that
writes:

```swift
@_spi(GeneratedClientSupport) import InnoNetwork
```

is opting into a pre-release-grade surface. We do not run breakage
audits against external `@_spi` consumers, and Issues that report
"`@_spi` symbol X disappeared in 5.y" will be closed with a pointer to
this section. Specifically:

- **Build errors** after a minor bump are expected and not regressions.
- **Pin to an exact InnoNetwork tag** (`.exact("4.0.0")`) if you import
  `@_spi`. `.upToNextMinor` is *not* tight enough.
- **Treat `@_spi` upgrades as code-level reviews** — diff the SPI
  surface in `Sources/InnoNetwork/...` and re-run your generator.

**4. Stable wrapper path is the supported escape hatch.**

If your generator does not need to own custom serialization or decoding,
prefer the stable `APIDefinition` / `MultipartAPIDefinition` wrapper
path. That path follows the standard `Stable` SemVer contract and never
requires `@_spi` import.

## Internal/Operational

- event pipeline metric payload and aggregation format
- append-log persistence format (`checkpoint.json`, `events.log`)
- reconnect taxonomy internal types and close disposition rules
- `InnoNetworkProtobuf` package composition and protobuf adapter surface
- package/internal request/response policy layers
- package/internal request execution pipeline stages that power auth refresh,
  coalescing, response cache, and circuit breaker features
- benchmark baseline contents and update cadence
- lower-level execution hooks that are present in source but not part of the
  4.0.0 stable public contract

## Notes

- Stable items follow semantic versioning for the 4.0.0 line once it is tagged.
- `default` aliases are convenience entry points and should be treated as `safeDefaults` aliases.
- Advanced builders are public and supported, but operational tuning values are not guaranteed to stay numerically identical across releases.
- `LowLevelNetworkClient`, `perform(_:)`, `perform(executable:)`,
  `SingleRequestExecutable`, `APISingleRequestExecutable`,
  `MultipartSingleRequestExecutable`, and `RequestPayload` are SPI surfaces.
  They are best-effort, are not part of the default SwiftPM import contract,
  and may evolve in any minor release without a deprecation window — see the
  SPI table under "Public Declaration Ledger" for the full list.
- `PublicKeyPinningPolicy.HostMatchingStrategy.unionAllMatches` preserves the
  existing host pin lookup behavior. `mostSpecificHost` is stable as an
  opt-in stricter matching mode for operators who separate parent and
  subdomain pins.
- `WebSocketCloseDisposition` is **Stable**; the observation property is
  SemVer-protected. Additional enum cases may be added in minor releases
  as new close-code classifications are formalised, but existing cases
  remain source-compatible.
- `WebSocketPingContext` and `WebSocketPongContext` public fields are stable
  because they are payloads of stable heartbeat events; their package-scoped
  initializers are construction details owned by the library.
- `WebSocketTask.attemptedReconnectCount` may transiently observe
  `maxReconnectAttempts + 1` during the failure transition that emits
  `.exceeded(reason: .attempts)`. The counter is bumped **before** the cap
  check so the rejected attempt itself is counted ("we tried and even this
  attempt was over the limit"), and the same one-off overshoot applies to
  the `.duration` exceed path. Observability layers that alert on the
  counter should treat values up to `max + 1` as in-spec and reach for the
  emitted `.exceeded` event to disambiguate.
- Resilience policies are opt-in and provisionally stable.
  `RequestExecutionPolicy` is the stable custom hook for one transport
  attempt; retry scheduling, auth refresh replay, response-cache substitution,
  coalescing, and circuit-breaker state remain owned by built-in pipeline
  stages that may evolve internally.
- `InnoNetworkCodegen` is a separate compile-time package under
  `Packages/InnoNetworkCodegen`. Importing the root `InnoNetwork` package does
  not resolve or build `swift-syntax`; macro users opt into that dependency by
  depending on the codegen package.
- Persistence and telemetry formats are not external storage contracts.
- Benchmark guard thresholds, guarded benchmark selection, and baseline
  contents are operational policy rather than public compatibility surface.
- Internal/Operational items may change in minor releases without separate deprecation windows.
- `NetworkError` is a `public` non-`@frozen` enum: new cases may be
  added in minor releases, with each addition documented in the
  changelog. Consumers who write exhaustive `switch` statements over
  `NetworkError` should add `@unknown default` to keep their code
  forward-compatible across minor bumps.
- `NetworkError.errorDescription` localization keys are a provisionally
  stable behaviour contract for 4.x. The initial catalogue ships English
  and Korean strings; additional localizations can be added in minor
  releases, but existing key meanings should not be repurposed without a
  changelog entry.

## Deprecation Policy

- Stable public APIs require a documented replacement before deprecation.
- Deprecations stay available for at least one minor release after the
  replacement ships, unless a security issue forces a faster removal.
- Provisionally stable APIs can change in minor releases, but each change must
  be called out in release notes with a migration path or an explicit statement
  that no source-compatible replacement exists yet.
- Internal/Operational items can change without deprecation because they are not
  part of the default SwiftPM import contract.

## 4.0.0 Migration Notes

These notes describe behaviour changes that landed during the 4.0.0
preparation cycle, where the published shape removes earlier
foot-guns. Each subsection captures the breaking change, the
rationale, and the supported migration. The matching `CHANGELOG.md`
entries live under `[4.0.0]`.

### `DownloadManager.shared` removed

- **What changed.** `DownloadManager.shared` is removed. There is no
  global singleton; every `DownloadManager` is constructed explicitly
  through `DownloadManager.make(configuration:)` (or
  `DownloadManager(configuration:)`).
- **Why.** The 4.x accessor trapped via `fatalError` on duplicate
  session identifiers, then briefly mitigated to an Optional that hid
  the failure mode behind a silent `nil`. Both shapes forced every
  feature in a process onto a single `DownloadConfiguration` and made
  the failure path either fatal or invisible. Removing the singleton
  keeps the failure shape (`DownloadManagerError.duplicateSessionIdentifier`)
  visible at the call site and lets each feature own its own
  configuration.
- **Migration.** Replace `DownloadManager.shared` with an injected
  manager owned by the feature module:

  ```swift
  let manager = try DownloadManager.make(
      configuration: .safeDefaults(sessionIdentifier: "com.example.media")
  )
  ```

  Pass that manager to whatever component performs the download
  (typically via initializer injection). For tests, construct a manager
  with a UUID-suffixed session identifier to avoid cross-test
  collisions.

### `NetworkClient` migrates to `throws(NetworkError)`

- **What changed.** Every `NetworkClient` primitive
  (`request(_:)`, `request(_:tag:)`, `upload(_:)`, `upload(_:tag:)`) now
  declares `async throws(NetworkError)`. The default forwarders in the
  protocol extension match. `NetworkError.mapTransportError(_:)` is
  promoted from `internal` to `public` so out-of-package conformers can
  map foreign errors (`URLError`, `CancellationError`, custom transport
  failures) to the canonical `NetworkError` representation.
- **Why.** `RetryCoordinator` already normalises every classified
  failure into `NetworkError`, and `DefaultNetworkClient` maps the
  remaining foreign errors at the boundary. The untyped `throws` was
  the only thing forcing callers to write `catch let error as
  NetworkError` plus a redundant `default` arm; making the contract
  explicit collapses the boilerplate without changing observable
  semantics.
- **Migration.** Call sites using `try await client.request(...)`
  compile unchanged. Conformers (mocks, fakes, decorators) must update
  the four method signatures to `async throws(NetworkError) -> ...`
  and convert any `throw error` that re-throws an arbitrary `Error`
  into either a `NetworkError` case or
  `NetworkError.mapTransportError(error)`.

### `NetworkClient` gains `tag:` overloads

- **What changed.** `NetworkClient` now declares
  `request(_:tag:)` and `upload(_:tag:)` alongside the existing
  un-tagged variants. The new methods accept an optional
  `CancellationTag` so callers can group requests for bulk cancellation
  via `DefaultNetworkClient.cancelAll(matching:)`.
- **Why.** `DefaultNetworkClient` already exposed the tagged path; the
  protocol omitted it, which meant code that programmed against
  `NetworkClient` could not opt into grouped cancellation without a
  cast. The 4.x asymmetry surfaced repeatedly in test stubs and
  generated clients.
- **Migration.** Existing call sites compile unchanged. `NetworkClient`
  conformers must implement the tagged overloads explicitly so grouped
  cancellation cannot be silently dropped by a default forwarding
  implementation. Stubs that do not own cancellable runtime work may
  forward to their untagged path, but wrappers around another
  `NetworkClient` should preserve the tag when delegating.

### `Endpoint` extracted from endpoint protocols

- **What changed.** A new `Endpoint` protocol now captures the
  HTTP envelope surface (`method`, `path`, `headers`, `logger`,
  `requestInterceptors`, `responseInterceptors`,
  `acceptableStatusCodes`, `transport`) shared by `APIDefinition` and
  `MultipartAPIDefinition`. Both protocols inherit from `Endpoint`
  and only declare their body-strategy surface (`parameters` /
  `multipartFormData` + `uploadStrategy`).
- **Why.** The two endpoint protocols duplicated identical
  requirements and identical default implementations. Consolidating
  them onto `Endpoint` removes a class of drift bugs (defaults
  silently diverging on one protocol but not the other) and gives
  generated clients a single vocabulary for "the envelope" without
  reaching for two parallel protocols.
- **Migration.** Endpoint conformances do not need to change. The
  shared defaults moved to an `Endpoint` extension, so any
  `APIDefinition` or `MultipartAPIDefinition` written against 4.x
  compiles unchanged. Only code that explicitly enumerated the parent
  protocol's requirements (for example, library-internal generic
  helpers) needs to redirect to `Endpoint`.

### `NetworkError.objectMapping` split into `decoding(stage:)`

- **What changed.** The `NetworkError.objectMapping(_:_:)` enum case
  and its compatibility static factory are both removed. Decode
  failures now surface exclusively as
  `NetworkError.decoding(stage:underlying:response:)` carrying a
  `DecodingStage` (`.responseBody`, `.streamFrame`) so the failure
  site is explicit. A new `NetworkError.isDecodingFailure` helper
  makes "decode failures are not retried" expressible without pattern
  matching.
- **Why.** `objectMapping` collapsed every decode-related failure —
  buffered body and per-frame streaming decode — into one case.
  Retry policies could not distinguish "the stream framing was
  malformed" from "the JSON body had a missing field",
  and observability layers had to inspect the underlying error to
  classify the stage. Splitting the case lets policies and metrics
  branch on stage directly.
- **Migration.** Replace construction sites that called
  `.objectMapping(underlying, response)` with
  `.decoding(stage: .responseBody, underlying: underlying, response: response)`.
  Pattern-matching `case .objectMapping(let underlying, let response)`
  must be migrated to
  `case .decoding(let stage, let underlying, let response)`. Callers
  that previously branched on "decode failure vs other" can use
  `error.isDecodingFailure` instead of pattern matching.

### `MultipartUploadStrategy.platformDefault` is now the default

- **What changed.** `MultipartAPIDefinition.uploadStrategy`'s default
  is now `MultipartUploadStrategy.platformDefault`, a memory-aware
  `streamingThreshold` that picks **16 MiB** on iOS, watchOS, and tvOS
  and **50 MiB** on macOS and visionOS. The 4.x default was an
  unconditional 50 MiB threshold across every platform.
- **Why.** iOS and tvOS jetsam, and watchOS extension memory limits,
  routinely killed apps that uploaded 30–40 MiB media payloads. The
  unconditional 50 MiB ceiling let `inMemory` encoding allocate well
  above the platform's working-set headroom before the streaming
  fallback kicked in. Splitting the default by platform aligns the
  encoded body's peak memory with the host OS's tolerance.
- **Migration.** Multipart endpoints that did not override
  `uploadStrategy` get the new behavior automatically. On iOS,
  watchOS, and tvOS, bodies between 16 MiB and 50 MiB now stream to
  a temp file instead of being held in `Data`; this trades a small
  amount of disk I/O for a much lower memory footprint. Endpoints
  that need the previous 50 MiB threshold on every platform should
  override `uploadStrategy` with
  `.streamingThreshold(bytes: 50 * 1024 * 1024)`. Endpoints that
  already explicitly chose `.inMemory`, `.alwaysStream`, or a
  specific `.streamingThreshold(bytes:)` are unaffected.

### `TimeoutReason.resourceTimeout` is metrics-aware

- **What changed.** The transport mapper now formally produces
  `TimeoutReason.resourceTimeout` when callers supply
  `URLSessionTaskMetrics` and the configured resource-timeout
  interval. The metrics-aware overload returns `.resourceTimeout` for
  `URLError.timedOut` only when the task interval reaches the
  resource budget; otherwise it falls back to `.requestTimeout`.
- **Why.** Earlier 4.x snapshots reserved `.resourceTimeout` for
  higher-level transports without producing it from the built-in
  mapper, so callers could not branch on the resource-vs-request
  distinction reliably.
- **Migration.** None for the single-argument mapper, which retains
  its prior behaviour. Callers that already constructed
  `NetworkError.timeout(reason: .resourceTimeout, …)` directly are
  unaffected.
