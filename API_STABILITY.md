# API Stability

This document defines the compatibility contract for the InnoNetwork 4.x
release line. `4.0.0` is the public baseline for this contract.

## Stable

- `APIDefinition`
- `CancellationTag`
- `EndpointShape`
- `MultipartAPIDefinition`
- `TransportPolicy`
- `RequestEncodingPolicy`
- `ResponseDecodingStrategy`
- `DefaultNetworkClient`
- `NetworkClient.request(_:)`
- `NetworkClient.request(_:tag:)`
- `NetworkClient.upload(_:)`
- `NetworkClient.upload(_:tag:)`
- `NetworkConfiguration.safeDefaults(baseURL:)`
- `NetworkConfiguration.advanced(baseURL:_:)`
- `DownloadConfiguration.safeDefaults()`
- `DownloadConfiguration.advanced(_:)`
- `WebSocketConfiguration.safeDefaults()`
- `WebSocketConfiguration.advanced(_:)`
- `WebSocketHandshakeRequestAdapter`
- `DownloadManager`
- `WebSocketManager`
- `WebSocketEvent.ping`
- `WebSocketEvent.pong`
- `WebSocketEvent.error(.pingTimeout)`
- `WebSocketPingContext`
- `WebSocketPongContext`
- `TrustPolicy`
- `PublicKeyPinningPolicy`
- `PublicKeyPinningPolicy.HostMatchingStrategy`
- `AnyResponseDecoder`
- `URLQueryEncoder`
- `URLQueryArrayEncodingStrategy`
- `ResponseBodyBufferingPolicy`
- `RequestExecutionPolicy`
- `EndpointAuthScope`
- `PublicAuthScope`
- `AuthRequiredScope`
- `StateReducer`
- `EventDeliveryPolicy`
- `WebSocketCloseCode`

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
  (currently `MockURLSession`, `WebSocketEventRecorder`, `StubBehavior`,
  `StubNetworkClient`, and `StubRequestKey`)
- `Endpoint`, `AuthenticatedEndpoint`, `ScopedEndpoint`, `EndpointPathEncoding`, `AnyEncodable`, `NetworkContext`, and `CorrelationIDInterceptor`
- `WebSocketCloseDisposition` observation surface
- `RefreshTokenPolicy`, `RequestCoalescingPolicy`, response cache, and circuit breaker policy surfaces
- `MultipartResponseDecoder` buffered multipart response parsing surface
- `InnoNetworkCodegen` separate package and macro declarations
- `DecodingInterceptor`

## Provisionally Stable Evolution Boundaries

Per-symbol evolution allowances within the 4.x line:

- `default` aliases — may add new defaults; never removed within 4.x.
- Benchmark runner CLI flags and JSON keys — may evolve to reflect new
  metrics; baseline contents are operational policy.
- README/DocC examples — track the stable APIs they illustrate; their
  exact wording is not part of the compatibility contract.
- `InnoNetworkTestSupport` — additional helpers may be added; existing
  symbols stay source-compatible within 4.x.
- `Endpoint`, `AnyEncodable`, `NetworkContext`, `CorrelationIDInterceptor` —
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
- `RequestExecutionPolicy` — custom policies may wrap raw transport attempts;
  built-in retry, refresh, cache, coalescing, and circuit breaker behavior
  remains provided by `NetworkConfiguration`.
- `EndpointAuthScope` — marker scopes can be added in future minors; the
  public/auth-required split remains source-compatible for 4.0.0.
- `MultipartAPIDefinition.Auth` — the multipart protocol carries the same
  `Auth: EndpointAuthScope` associated type as `APIDefinition`, defaulted to
  `PublicAuthScope`. Existing multipart endpoints stay source-compatible;
  authenticated multipart uploads must declare `typealias Auth = AuthRequiredScope`
  to participate in `RefreshTokenPolicy` validation.
- `StateReducer` — public reducer vocabulary for lifecycle state machines;
  package products can use it for internal reducers while keeping effect
  execution owned by their managers.
- `WebSocketCloseDisposition` — additional enum cases may appear as new
  close-code classifications are formalized.
- `RefreshTokenPolicy`, `RequestCoalescingPolicy`, response cache, and
  circuit breaker policy — built-in knobs may add fields with
  source-compatible defaults; the generic execution pipeline stays
  package/internal.
- `MultipartResponseDecoder` — may evolve as the streaming-multipart
  roadmap progresses.
- `InnoNetworkCodegen` — macro signatures may add optional arguments.
- `DecodingInterceptor` — protocol may grow new optional hooks with
  default implementations as additional decode-boundary use cases
  surface.

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
compares them with `Scripts/api_public_symbols.allowlist`. That catches nested
public types and members such as `NetworkConfiguration.AdvancedBuilder` in
addition to top-level declarations. The grouped ledger below keeps the
high-level compatibility classification readable for the 4.x release line.

### InnoNetwork

- `APIDefinition`, `AnyEncodable`, `AnyRequestExecutionPolicy`,
  `AnyResponseDecoder`, `AuthRequiredScope`, `AuthenticatedEndpoint`,
  `CachedResponse`, `CancellationTag`,
  `CircuitBreakerOpenError`, `CircuitBreakerPolicy`,
  `ContentType`, `CorrelationIDInterceptor`, `DecodingStage`,
  `DefaultNetworkClient`,
  `DefaultNetworkLogger`, `EmptyParameter`, `EmptyResponse`, `Endpoint`,
  `EndpointAuthScope`, `EndpointPathEncoding`, `EndpointShape`,
  `HTTPEmptyResponseDecodable`, `HTTPHeader`, `HTTPHeaders`, `HTTPMethod`,
  `InMemoryResponseCache`, `MultipartAPIDefinition`, `MultipartFormData`,
  `MultipartPart`, `MultipartResponseDecoder`, `MultipartUploadStrategy`,
  `NetworkClient`, `NetworkConfiguration`, `NetworkContext`, `NetworkError`,
  `NetworkEvent`, `NetworkEventObserving`, `NetworkInterfaceType`,
  `NetworkLoggingOptions`, `NetworkLogger`, `NetworkMetricsReporting`,
  `NetworkMonitor`, `NetworkMonitoring`, `NetworkReachabilityStatus`,
  `NetworkRequestContext`, `NetworkSnapshot`, `NoOpNetworkEventObserver`,
  `NoOpNetworkLogger`, `OSLogNetworkEventObserver`, `PublicAuthScope`,
  `PublicKeyPinningPolicy`,
  `RefreshTokenPolicy`, `RequestCoalescingPolicy`, `RequestEncodingPolicy`,
  `RequestInterceptor`, `Response`, `ResponseCache`, `ResponseCacheKey`,
  `RequestExecutionContext`, `RequestExecutionInput`, `RequestExecutionNext`,
  `RequestExecutionPolicy`, `ResponseBodyBufferingPolicy`,
  `ResponseCachePolicy`, `ResponseDecodingStrategy`, `ResponseInterceptor`,
  `RetryDecision`, `RetryIdempotencyPolicy`, `RetryPolicy`,
  `ScopedEndpoint`, `SendableUnderlyingError`, `ServerSentEvent`,
  `ServerSentEventDecoder`, `StateReducer`, `StateReduction`,
  `StreamingAPIDefinition`, `StreamingResumePolicy`, `TimeoutReason`,
  `TransportPolicy`, `TrustEvaluating`, `TrustFailureReason`, `TrustPolicy`,
  `URLQueryArrayEncodingStrategy`, `URLQueryCustomKeyTransform`,
  `URLQueryEncoder`, `URLQueryKeyEncodingStrategy`, and `URLSessionProtocol`.
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
  `WebSocketPingContext`, `WebSocketPongContext`, `WebSocketSendOverflowPolicy`,
  `WebSocketState`, and `WebSocketTask`.

### InnoNetworkPersistentCache

- `PersistentResponseCache` and `PersistentResponseCacheConfiguration`.

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

### InnoNetworkTestSupport

- `MockURLSession`, `StubBehavior`, `StubNetworkClient`, `StubRequestKey`, and
  `WebSocketEventRecorder`.

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
- `WebSocketCloseDisposition` is provisionally stable; the observation property
  stays public, while classification policy and additional enum cases may evolve
  in minor releases.
- `WebSocketPingContext` and `WebSocketPongContext` public fields are stable
  because they are payloads of stable heartbeat events; their package-scoped
  initializers are construction details owned by the library.
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

### `EndpointShape` extracted from endpoint protocols

- **What changed.** A new `EndpointShape` protocol now captures the
  HTTP envelope surface (`method`, `path`, `headers`, `logger`,
  `requestInterceptors`, `responseInterceptors`,
  `acceptableStatusCodes`, `transport`) shared by `APIDefinition` and
  `MultipartAPIDefinition`. Both protocols inherit from `EndpointShape`
  and only declare their body-strategy surface (`parameters` /
  `multipartFormData` + `uploadStrategy`).
- **Why.** The two endpoint protocols duplicated identical
  requirements and identical default implementations. Consolidating
  them onto `EndpointShape` removes a class of drift bugs (defaults
  silently diverging on one protocol but not the other) and gives
  generated clients a single vocabulary for "the envelope" without
  reaching for two parallel protocols.
- **Migration.** Endpoint conformances do not need to change. The
  shared defaults moved to an `EndpointShape` extension, so any
  `APIDefinition` or `MultipartAPIDefinition` written against 4.x
  compiles unchanged. Only code that explicitly enumerated the parent
  protocol's requirements (for example, library-internal generic
  helpers) needs to redirect to `EndpointShape`.

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
