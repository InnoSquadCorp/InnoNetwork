# API Stability

This document defines the compatibility contract for the public OSS release of InnoNetwork 3.x.

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
- `TrustPolicy`
- `AnyResponseDecoder`
- `URLQueryEncoder`
- `EventDeliveryPolicy`

## Provisionally Stable

- `NetworkClient.perform(_:)`
- `NetworkClient.perform(executable:)`
- `SingleRequestExecutable`
- `RequestPayload`
- `default` aliases on configuration types
- benchmark runner CLI flags and JSON summary presentation details
- troubleshooting guidance and examples in README/DocC

## Internal/Operational

- event pipeline metric payload and aggregation format
- append-log persistence format (`checkpoint.json`, `events.log`)
- reconnect taxonomy internal types and close disposition rules
- `InnoNetworkProtobuf` package composition and protobuf adapter surface
- package/internal request/response policy layers
- benchmark baseline contents and update cadence

## Notes

- Stable items follow semantic versioning for the 3.x line.
- `default` aliases are convenience entry points and should be treated as `safeDefaults` aliases.
- Advanced builders are public and supported, but operational tuning values are not guaranteed to stay numerically identical across releases.
- `perform(_:)`, `perform(executable:)`, `SingleRequestExecutable`, and
  `RequestPayload` are public extension points for higher networking layers. They
  are expected to remain available across 3.x, but their exact low-level
  affordances may evolve with minor releases.
- Persistence and telemetry formats are not external storage contracts.
- Internal/Operational items may change in minor releases without separate deprecation windows.
