# API Stability

This document defines the compatibility contract for the InnoNetwork 4.x
release line. `4.0.0` is the upcoming public release baseline for this
contract; until it is tagged, validate the line with `release/v4.0` or a
specific repository revision.

## Stable

- `APIDefinition`
- `MultipartAPIDefinition`
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
- `InnoNetworkCodegen` optional macro product and macro declarations

## Public Declaration Ledger

The docs-contract gate extracts public symbols from Swift symbol graphs and
compares them with `Scripts/api_public_symbols.allowlist`. That catches nested
public types and members such as `NetworkConfiguration.AdvancedBuilder` in
addition to top-level declarations. The grouped ledger below keeps the
high-level compatibility classification readable for the 4.x release line.

### InnoNetwork

- `APIDefinition`, `AnyEncodable`, `AnyResponseDecoder`, `CachedResponse`,
  `CircuitBreakerOpenError`, `CircuitBreakerPolicy`, `ContentType`,
  `CorrelationIDInterceptor`, `DefaultNetworkClient`, `DefaultNetworkLogger`,
  `EmptyParameter`, `EmptyResponse`, `Endpoint`, `HTTPEmptyResponseDecodable`,
  `HTTPHeader`, `HTTPHeaders`, `HTTPMethod`, `InMemoryResponseCache`,
  `MultipartAPIDefinition`, `MultipartFormData`, `MultipartPart`,
  `MultipartResponseDecoder`, `MultipartUploadStrategy`, `NetworkClient`,
  `NetworkConfiguration`, `NetworkContext`, `NetworkError`, `NetworkEvent`,
  `NetworkEventObserving`, `NetworkInterfaceType`, `NetworkLoggingOptions`,
  `NetworkLogger`, `NetworkMetricsReporting`, `NetworkMonitor`,
  `NetworkMonitoring`, `NetworkReachabilityStatus`, `NetworkRequestContext`,
  `NetworkSnapshot`, `NoOpNetworkEventObserver`, `NoOpNetworkLogger`,
  `OSLogNetworkEventObserver`, `PublicKeyPinningPolicy`, `RefreshTokenPolicy`,
  `RequestCoalescingPolicy`, `RequestInterceptor`, `Response`,
  `ResponseCache`, `ResponseCacheKey`, `ResponseCachePolicy`,
  `ResponseInterceptor`, `RetryDecision`, `RetryPolicy`,
  `SendableUnderlyingError`, `ServerSentEvent`, `ServerSentEventDecoder`,
  `StreamingAPIDefinition`, `StreamingResumePolicy`, `TimeoutReason`,
  `TrustEvaluating`, `TrustFailureReason`, `TrustPolicy`,
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

### InnoNetworkCodegen

- `APIDefinition(method:path:)` attached macro.
- `endpoint(_:_:as:)` freestanding expression macro.

### SPI

- `LowLevelNetworkClient`, `RequestPayload`, and `SingleRequestExecutable` are
  public only through `@_spi(GeneratedClientSupport)` and remain outside the
  default SwiftPM import contract.

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
  `SingleRequestExecutable`, and `RequestPayload` are SPI surfaces and are not
  part of the default SwiftPM import contract.
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
- `InnoNetworkCodegen` is an optional compile-time product. Importing only
  `InnoNetwork` does not link `swift-syntax` into the core runtime target.
  SwiftPM may still resolve package-level macro dependencies while loading the
  full package graph.
- Persistence and telemetry formats are not external storage contracts.
- Benchmark guard thresholds, guarded benchmark selection, and baseline
  contents are operational policy rather than public compatibility surface.
- Internal/Operational items may change in minor releases without separate deprecation windows.
