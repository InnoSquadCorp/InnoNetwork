# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and the project follows Semantic Versioning for the public 3.x line.

## [Unreleased]

### Added

- No unreleased entries yet.

### Changed

- No unreleased entries yet.

## [4.0.0]

This release raises the Swift language baseline, tightens the WebSocket API
around a typed close-code enum, and adds a matching `.ping` observability
event. See [`MIGRATION_v4.md`](MIGRATION_v4.md) for a step-by-step call-site
diff.

### Added

- `WebSocketCloseCode` is now public and usable for pattern matching across
  the full RFC 6455 range (1000–1015) plus library/application `.custom(UInt16)`
  codes (3000–4999). The previously-absent `.serviceRestart` (1012) and
  `.tryAgainLater` (1013) cases are first-class values.
- `WebSocketEvent.ping` is emitted immediately before every heartbeat or public
  `ping(_:)` attempt, pairing with the existing `.pong`/`.error(.pingTimeout)`
  completion events to give callers a full "attempt → outcome" timeline.

### Changed

- **BREAKING**: `WebSocketManager.disconnect(_:closeCode:)` and
  `WebSocketManager.disconnectAll(closeCode:)` now take `WebSocketCloseCode`
  instead of `URLSessionWebSocketTask.CloseCode`. The default value
  (`.normalClosure`) is unchanged, so call sites that only used defaults keep
  compiling after rebuild.
- **BREAKING**: `WebSocketTask.closeCode` returns `WebSocketCloseCode?` instead
  of `URLSessionWebSocketTask.CloseCode?`. Pattern matches on Apple-provided
  cases (`.normalClosure`, `.goingAway`, etc.) keep working because the enum
  uses the same case names.
- Swift 6 language mode (`swiftLanguageMode(.v6)`) is enabled on every target.
  The package still compiles under Swift 6.2+ toolchains; CI no longer needs
  the explicit `-strict-concurrency=complete` flag.

### Fixed

- All remaining `@unchecked Sendable` usages in production sources are gone:
  `URLQueryEncoder`, `URLQueryCustomKeyTransform`, `SnakeCaseKeyTransformCache`,
  and `EventPipelineMetricsReporterProxy` now carry plain `Sendable` or
  lock-guarded state. The old `Scripts/unchecked_sendable_allowlist.txt` is
  removed; CI rejects any new `@unchecked Sendable` in `Sources/`.

## [3.1.0]

### Added

- Public typed execution entry points via `LowLevelNetworkClient.perform(_:)` and `LowLevelNetworkClient.perform(executable:)`
- Public `SingleRequestExecutable` contract for higher networking and policy layers
- Public `RequestPayload` contract used by `SingleRequestExecutable.makePayload()`
- README, DocC, and API stability guidance that defines `request` and `upload` as the default integration APIs and `perform(executable:)` as the supported low-level extension point

### Changed

- `DefaultNetworkClient.request(_:)` and `DefaultNetworkClient.upload(_:)` now delegate through the same public low-level execution path used by `perform`
- API stability policy now treats `LowLevelNetworkClient`, `perform(_:)`, `perform(executable:)`, `SingleRequestExecutable`, and `RequestPayload` as provisionally stable extension points for the `3.x` line

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
