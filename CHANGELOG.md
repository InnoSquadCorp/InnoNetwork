# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and the project follows Semantic
Versioning for the upcoming 4.0.0 public release line.

## [4.0.0] - Unreleased

This release raises the Swift language baseline, tightens the WebSocket API
around a typed close-code enum, and adds a matching `.ping` observability
event. See [`MIGRATION_v4.md`](MIGRATION_v4.md) for a step-by-step call-site
diff.

### Added

- `WebSocketCloseCode` is now public and usable for pattern matching across
  the full RFC 6455 range (1000-1015) plus library/application
  `.custom(UInt16)` codes (3000-4999). The previously absent
  `.serviceRestart` (1012) and `.tryAgainLater` (1013) cases are first-class
  values.
- `WebSocketEvent.ping` is emitted immediately before every heartbeat or public
  `ping(_:)` attempt, pairing with the existing `.pong` /
  `.error(.pingTimeout)` completion events to give callers a full
  "attempt -> outcome" timeline.

### Changed

- **BREAKING**: `WebSocketManager.disconnect(_:closeCode:)` and
  `WebSocketManager.disconnectAll(closeCode:)` now take `WebSocketCloseCode`
  instead of `URLSessionWebSocketTask.CloseCode`. The default value
  (`.normalClosure`) is unchanged, so call sites that only used defaults keep
  compiling after rebuild.
- **BREAKING**: `WebSocketTask.closeCode` returns `WebSocketCloseCode?`
  instead of `URLSessionWebSocketTask.CloseCode?`. Pattern matches on
  Apple-provided cases (`.normalClosure`, `.goingAway`, etc.) keep working
  because the enum uses the same case names.
- Swift 6 language mode (`swiftLanguageMode(.v6)`) is enabled on every target.
  The package compiles under Swift 6.2+ toolchains; CI no longer needs the
  explicit `-strict-concurrency=complete` flag.

### Fixed

- All remaining `@unchecked Sendable` usages in production sources are gone.
  CI rejects any new `@unchecked Sendable` in shipping library targets.

## Pre-4.0 history

Pre-4.0 changes are preserved in git history and earlier tags. This changelog
now focuses on the upcoming 4.0.0 public release contract so pre-release
documentation, migration notes, and API stability policy stay aligned.
