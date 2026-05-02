# API Stability

This document defines the compatibility contract for the InnoNetwork 4.x
release line. `4.0.0` is the public baseline for this contract.

> **5.0 work-in-progress:** the `main` branch is preparing the 5.0 major
> release. Breaking changes that ship before the 5.0 tag are listed under
> the "5.0 Migration Guide" section below and are also captured in
> `CHANGELOG.md` under the `[Unreleased]` heading. Until 5.0 is tagged,
> the contract documented in the rest of this file describes the published
> 4.x line; integrators tracking `main` should review the migration guide
> on every minor bump.

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
- `Endpoint`, `EndpointPathEncoding`, `AnyEncodable`, `NetworkContext`, and `CorrelationIDInterceptor`
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

Apps that consume InnoNetwork via SwiftPM should pin against the latest
4.x minor:

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

- `APIDefinition`, `AnyEncodable`, `AnyResponseDecoder`, `CachedResponse`,
  `CancellationTag`, `CircuitBreakerOpenError`, `CircuitBreakerPolicy`,
  `ContentType`, `CorrelationIDInterceptor`, `DecodingStage`,
  `DefaultNetworkClient`,
  `DefaultNetworkLogger`, `EmptyParameter`, `EmptyResponse`, `Endpoint`,
  `EndpointPathEncoding`, `EndpointShape`, `HTTPEmptyResponseDecodable`, `HTTPHeader`, `HTTPHeaders`, `HTTPMethod`,
  `InMemoryResponseCache`, `MultipartAPIDefinition`, `MultipartFormData`,
  `MultipartPart`, `MultipartResponseDecoder`, `MultipartUploadStrategy`,
  `NetworkClient`, `NetworkConfiguration`, `NetworkContext`, `NetworkError`,
  `NetworkEvent`, `NetworkEventObserving`, `NetworkInterfaceType`,
  `NetworkLoggingOptions`, `NetworkLogger`, `NetworkMetricsReporting`,
  `NetworkMonitor`, `NetworkMonitoring`, `NetworkReachabilityStatus`,
  `NetworkRequestContext`, `NetworkSnapshot`, `NoOpNetworkEventObserver`,
  `NoOpNetworkLogger`, `OSLogNetworkEventObserver`, `PublicKeyPinningPolicy`,
  `RefreshTokenPolicy`, `RequestCoalescingPolicy`, `RequestEncodingPolicy`,
  `RequestInterceptor`, `Response`, `ResponseCache`, `ResponseCacheKey`,
  `ResponseCachePolicy`, `ResponseDecodingStrategy`, `ResponseInterceptor`,
  `RetryDecision`, `RetryIdempotencyPolicy`, `RetryPolicy`,
  `SendableUnderlyingError`, `ServerSentEvent`, `ServerSentEventDecoder`,
  `StreamingAPIDefinition`, `StreamingResumePolicy`, `TimeoutReason`,
  `TransportPolicy`, `TrustEvaluating`, `TrustFailureReason`, `TrustPolicy`,
  `URLQueryCustomKeyTransform`, `URLQueryEncoder`, `URLQueryKeyEncodingStrategy`,
  and `URLSessionProtocol`.
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
- Resilience policies are opt-in and provisionally stable. They expose
  built-in knobs only; the generic execution pipeline remains package/internal
  and may evolve without deprecation.
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

## 5.0 Migration Guide

The 5.0 line is staged on `main` and removes a small set of foot-guns that
4.x carried for source-compatibility. Each subsection describes the
breaking change, the rationale, and the supported migration. Items here
land before the 5.0 tag and are also tracked in `CHANGELOG.md`
`[Unreleased]`.

### `DownloadManager.shared` is now Optional

- **What changed.** `DownloadManager.shared` previously trapped via
  `fatalError` when its session identifier was already claimed by another
  manager. In 5.0 the property is typed as `DownloadManager?` and returns
  `nil` after logging an OSLog `.fault` instead of crashing the process.
- **Why.** The trap turned a recoverable identifier collision (typically
  caused by tests, app extensions sharing an identifier, or repeated
  `make(configuration:)` calls) into an app crash. Returning `nil` lets
  callers fall back to `make(configuration:)` and surface their own error.
- **Migration.** Prefer `DownloadManager.make(configuration:)`. If you
  must touch `shared`, unwrap it explicitly:

  ```swift
  guard let manager = DownloadManager.shared else {
      // Fall back to a deliberately-configured manager.
      return try DownloadManager.make(configuration: .default)
  }
  ```

  `shared` remains `@available(*, deprecated)` to nudge callers toward
  `make(configuration:)`; it will be removed in a later major release.

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
- **Migration.** Existing call sites compile unchanged. Conformers that
  do not implement the tagged overloads inherit a default extension
  that forwards to the un-tagged variant and ignores the tag, so
  out-of-tree stubs (for example `StubNetworkClient`) continue to
  build. Conformers that *do* support cancellation grouping should
  override the new methods to honor the tag.

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

- **What changed.** The `NetworkError.objectMapping(_:_:)` enum case is
  removed. Decode failures now surface as
  `NetworkError.decoding(stage:underlying:response:)` carrying a
  `DecodingStage` (`.responseBody`, `.streamFrame`, `.multipartPart`,
  `.envelope`, `.empty`) so the failure site is explicit. A
  source-compatible static factory `NetworkError.objectMapping(_:_:)`
  remains, marked `@available(*, deprecated, renamed:)`, so existing
  *construction* sites compile with a deprecation warning. A new
  `NetworkError.isDecodingFailure` helper makes "decode failures are
  not retried" expressible without pattern matching.
- **Why.** `objectMapping` collapsed every decode-related failure —
  body, stream frame, multipart part, envelope, and empty-body —
  into one case. Retry policies could not distinguish "the stream
  framing was malformed" from "the JSON body had a missing field",
  and observability layers had to inspect the underlying error to
  classify the stage. Splitting the case lets policies and metrics
  branch on stage directly.
- **Migration.** Construction sites compile with a deprecation
  warning; switch to
  `NetworkError.decoding(stage: .responseBody, underlying:, response:)`.
  Pattern-matching `case .objectMapping(let underlying, let response)`
  must be migrated to
  `case .decoding(let stage, let underlying, let response)`; this is
  a hard break because Swift cannot alias enum-case patterns. Callers
  that previously branched on "decode failure vs other" can use
  `error.isDecodingFailure` instead of pattern matching.

### Forward-looking notes

Additional 5.0 commits (platform-aware multipart streaming defaults,
formalized `TimeoutReason.resourceTimeout` mapping) will append
migration sections here as they land. Each will ship with a deprecated
alias whenever a single-step migration is feasible.
