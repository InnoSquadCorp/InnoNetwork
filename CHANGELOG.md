# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and the project follows Semantic Versioning for the public 3.x line.

## [Unreleased]

### Added

- No unreleased entries yet.

### Changed

- Protocol Buffers support is being prepared to move into the separate `InnoNetworkProtobuf` package in the next major release.

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
