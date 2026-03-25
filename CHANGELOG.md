# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and the project follows Semantic Versioning for the public 3.x line.

## [Unreleased]

### Added

- No unreleased entries yet.

### Changed

- No unreleased entries yet.

## [3.1.0]

### Added

- Public low-level typed execution entry points via `NetworkClient.perform(_:)`
- Public `SingleRequestExecutable` contract for higher networking and policy layers
- Public `RequestPayload` contract used by `SingleRequestExecutable.makePayload()`
- README, DocC, and API stability guidance that defines `request` and `upload` as the default integration APIs and `perform` as the supported low-level extension point

### Changed

- `DefaultNetworkClient.request(_:)` and `DefaultNetworkClient.upload(_:)` now delegate through the same public low-level execution path used by `perform(_:)`
- API stability policy now treats `perform(_:)` and `SingleRequestExecutable` as provisionally stable extension points for the `3.x` line

### Fixed

- Higher-level networking layers no longer need SPI imports to plug custom request serialization into `InnoNetwork`

## [3.0.1]

### Added

- Public OSS release for `InnoNetwork`, `InnoNetworkDownload`, and `InnoNetworkWebSocket`
- `safeDefaults` and `advanced` configuration entry points across core, download, and websocket modules
- Docs / contract sync automation, doc smoke target, and consumer smoke validation
- Dedicated benchmark target with diff-only governance and baseline artifacts
- OSS governance documents, release policy, migration policy, support policy, and issue / PR templates

### Changed

- Request / response execution is now organized around internal transport policies and explicit decoding strategies
- Query and form encoding are handled by a dedicated `URLQueryEncoder` with deterministic ordering
- Event delivery uses bounded buffering, listener isolation, and operational telemetry
- Download persistence now uses append-log durability instead of lightweight defaults storage
- WebSocket reconnect behavior uses handshake-aware close taxonomy and reconnect suppression rules

### Fixed

- Empty response handling no longer relies on force casts
- Consumer-facing examples and README paths now prefer `safeDefaults` and current release guidance

## [3.0.0]

### Added

- Public OSS release for `InnoNetwork`, `InnoNetworkDownload`, and `InnoNetworkWebSocket`
- `safeDefaults` and `advanced` configuration entry points across core, download, and websocket modules
- Docs / contract sync automation, doc smoke target, and consumer smoke validation
- Dedicated benchmark target with diff-only governance and baseline artifacts
- OSS governance documents, release policy, migration policy, support policy, and issue / PR templates

### Changed

- Request / response execution is now organized around internal transport policies and explicit decoding strategies
- Query and form encoding are handled by a dedicated `URLQueryEncoder` with deterministic ordering
- Event delivery uses bounded buffering, listener isolation, and operational telemetry
- Download persistence now uses append-log durability instead of lightweight defaults storage
- WebSocket reconnect behavior uses handshake-aware close taxonomy and reconnect suppression rules

### Fixed

- Empty response handling no longer relies on force casts
- Consumer-facing examples and README paths now prefer `safeDefaults` and current release guidance
