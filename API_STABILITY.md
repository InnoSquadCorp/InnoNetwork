# API Stability

This document defines the compatibility contract for the InnoNetwork 4.x
release line. `4.0.0` is the public baseline for this contract.

## Stable

- `APIDefinition`
- `CancellationTag`
- `MultipartAPIDefinition`
- `TransportPolicy`
- `RequestEncodingPolicy`
- `ResponseDecodingStrategy`
- `DefaultNetworkClient`
- `NetworkClient.request(_:)`
- `NetworkClient.upload(_:)`
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
- `Endpoint`, `AnyEncodable`, `NetworkContext`, and `CorrelationIDInterceptor`
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
  `ContentType`, `CorrelationIDInterceptor`, `DefaultNetworkClient`,
  `DefaultNetworkLogger`, `EmptyParameter`, `EmptyResponse`, `Endpoint`,
  `HTTPEmptyResponseDecodable`, `HTTPHeader`, `HTTPHeaders`, `HTTPMethod`,
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
