# API Stability

This document defines the compatibility contract for the upcoming InnoNetwork
4.0.0 public release.

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
- `DownloadManager`
- `WebSocketManager`
- `WebSocketEvent.ping`
- `WebSocketEvent.pong`
- `WebSocketEvent.error(.pingTimeout)`
- `WebSocketPingContext`
- `WebSocketPongContext`
- `TrustPolicy`
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

## Public Declaration Ledger

The docs-contract gate extracts top-level `public` declarations from shipping
targets and requires every declaration below to stay classified here before the
4.0.0 tag.

### InnoNetwork

- `APIDefinition`, `AnyEncodable`, `AnyResponseDecoder`, `ContentType`,
  `CorrelationIDInterceptor`, `DefaultNetworkClient`, `DefaultNetworkLogger`,
  `EmptyParameter`, `EmptyResponse`, `Endpoint`, `HTTPEmptyResponseDecodable`,
  `HTTPHeader`, `HTTPHeaders`, `HTTPMethod`, `MultipartAPIDefinition`,
  `MultipartFormData`, `MultipartUploadStrategy`, `NetworkClient`,
  `NetworkConfiguration`, `NetworkContext`, `NetworkError`, `NetworkEvent`,
  `NetworkEventObserving`, `NetworkInterfaceType`, `NetworkLoggingOptions`,
  `NetworkLogger`, `NetworkMetricsReporting`, `NetworkMonitor`,
  `NetworkMonitoring`, `NetworkReachabilityStatus`, `NetworkRequestContext`,
  `NetworkSnapshot`, `NoOpNetworkEventObserver`, `NoOpNetworkLogger`,
  `OSLogNetworkEventObserver`, `PublicKeyPinningPolicy`, `RequestInterceptor`,
  `Response`, `ResponseInterceptor`, `RetryDecision`, `RetryPolicy`,
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
  `WebSocketManager`, `WebSocketPingContext`, `WebSocketPongContext`,
  `WebSocketSendOverflowPolicy`, `WebSocketState`, and `WebSocketTask`.

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
- benchmark baseline contents and update cadence
- lower-level execution hooks that are present in source but not part of the
  4.0.0 stable public contract

## Notes

- Stable items follow semantic versioning for the 4.0.0 line once it is tagged.
- `default` aliases are convenience entry points and should be treated as `safeDefaults` aliases.
- Advanced builders are public and supported, but operational tuning values are not guaranteed to stay numerically identical across releases.
- `LowLevelNetworkClient`, `perform(_:)`, `perform(executable:)`,
  `SingleRequestExecutable`, `RequestPayload`, and
  `WebSocketCloseDisposition` may appear in source while the package is being
  prepared, but they are not part of the 4.0.0 stable API promise.
- `WebSocketPingContext` and `WebSocketPongContext` public fields are stable
  because they are payloads of stable heartbeat events; their package-scoped
  initializers are construction details owned by the library.
- Persistence and telemetry formats are not external storage contracts.
- Benchmark guard thresholds, guarded benchmark selection, and baseline
  contents are operational policy rather than public compatibility surface.
- Internal/Operational items may change in minor releases without separate deprecation windows.
