# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and the project follows Semantic
Versioning for the upcoming 4.0.0 public release line.

## [4.1.0] - Unreleased

The 4.1 line is a risk-mitigation epic on top of 4.0. It is additive on the
public API surface — no breaking changes, with one compatibility deprecation
alias (`WebSocketTask.reconnectCount`). New surfaces ship with conservative
defaults so existing call sites keep current behaviour. See
[`docs/releases/4.1.0.md`](docs/releases/4.1.0.md) for a one-page summary.

### Added

- `APIDefinition`, `MultipartAPIDefinition`, and `StreamingAPIDefinition`
  expose `acceptableStatusCodes: Set<Int>?` for per-endpoint overrides of
  the session-wide default.
- `WebSocketTask` exposes `attemptedReconnectCount` and
  `successfulReconnectCount`. The legacy `reconnectCount` property is
  available as a deprecated alias of `attemptedReconnectCount` for source
  compatibility.
- `DownloadManager.make(configuration:) throws` factory mirrors the throwing
  initializer with a more discoverable name. `DownloadManager.shared` no
  longer crashes on duplicate-session-identifier conflicts; it logs an
  OSLog `.fault`, asserts in DEBUG, and falls back to a process-unique
  identifier so the singleton stays usable.
- `StreamingResumePolicy` (`.disabled`, `.lastEventID(maxAttempts:retryDelay:)`)
  drives optional reconnect-with-Last-Event-ID resume on streaming endpoints.
  `StreamingAPIDefinition.eventID(from:)` is the user hook that feeds the
  resume header.
- `MultipartUploadStrategy` (`.inMemory`, `.streamingThreshold(bytes:)`,
  `.alwaysStream`) selects between in-memory body assembly and streaming
  the multipart body to a temp file before upload. Default is `.inMemory`
  so existing endpoints stay unchanged.
  `MultipartFormData.estimatedEncodedSize` reports the projected wire size.
- `NetworkConfiguration.captureFailurePayload` (default `false`) controls
  whether `NetworkError`'s attached `Response.data` is preserved or
  redacted. `NetworkError.redactingFailurePayload()` and
  `Response.redactingData()` expose the helpers used by the executor.
- `WebSocketConfiguration.sendQueueLimit` and `sendQueueOverflowPolicy`
  (`.fail` / `.dropNewest`) bound per-task in-flight send concurrency.
  `WebSocketError.sendQueueOverflow(limit:)` and
  `WebSocketEvent.sendDropped(limit:)` surface back-pressure outcomes.
  `WebSocketTask.inFlightSendCount` reports the live counter.
- DocC catalogs ship with onboarding articles for retry decisions, error
  classification, trust policies, background downloads, persistence,
  WebSocket close codes, and reconnect behaviour. The rendered site lives
  at https://innosquadcorp.github.io/InnoNetwork/.
- New documentation: `docs/PlatformSupport.md`, `docs/QueryEncoding.md`,
  `docs/WebSocketLifecycle.md`, `docs/ko/README.md` (Korean mirror of the
  README), and a Production Checklist section in the README.
- New `InnoNetworkLiveTests` test target (gated behind `INNO_LIVE=1`) plus
  a daily `nightly-live` GitHub Actions workflow. Cases cover httpbin GET /
  POST / 503 and ws.postman-echo string echo.
- Parametrized `URLQueryEncoderParametrizedTests` suite locks down the
  PHP/Rails-style bracket-notation invariants, sorted-key determinism,
  rootKey enforcement, and reserved-character handling.
- Release artifacts (`benchmarks.json`, `sbom.cdx.json`) are signed with
  sigstore cosign keyless signatures. SECURITY.md describes the
  `cosign verify-blob` invocation.

### Changed

- `RequestExecutor` and `DefaultNetworkClient.stream(_:)` now apply
  `NetworkError.redactingFailurePayload()` to errors before logging or
  surfacing them, unless the caller opts in via
  `NetworkConfiguration.captureFailurePayload`. Behaviour change for
  callers that inspected `Response.data` on an error: that field is now
  empty by default. Status code, request URL, headers, and the
  `HTTPURLResponse` are preserved.
- CI: `swift test` runs with `--enable-code-coverage`; coverage is uploaded
  as an artifact and forwarded to Codecov when `CODECOV_TOKEN` is present.
  The benchmark smoke guard threshold remains at 50% pending a baseline
  refresh against the v4.1 build (the existing baseline pre-dates the
  WebSocket send-queue work and would false-positive at 10%). The
  tightening to 10% is tracked in [`docs/ROADMAP.md`](docs/ROADMAP.md).
- The release workflow generates a CycloneDX 1.5 SBOM and signs both the
  SBOM and the benchmark snapshot with sigstore cosign before attaching
  them to the GitHub Release.
- README documents the destination filename policy for
  `DownloadManager.download(url:toDirectory:fileName:)` (no rename on
  collision).
- `docs/QueryEncoding.md` formalises the `URLQueryEncoder` flattening
  rules (PHP/Rails-style bracket notation) and contrasts them with
  OpenAPI form/explode, RFC 6570, Spring, and FastAPI conventions.

### Deprecated

- `WebSocketTask.reconnectCount` — use `attemptedReconnectCount` instead.

### Concurrency

- `DownloadManager` is now a `public actor`. NSObject inheritance and
  `super.init()` are gone; URL-session delegate callbacks enqueue into one
  delegate-event stream that a single consumer drains into the actor.
  Public API surface is unchanged because every public method was already
  `async`. `handleBackgroundSessionCompletion(_:completion:)` is
  `nonisolated` so the synchronous Foundation entry point keeps working.
- `DownloadConfiguration.persistenceFsyncPolicy: PersistenceFsyncPolicy`
  picks one of `.always`, `.onCheckpoint` (default), `.never` for the
  append-log durability barrier. The store calls `Darwin.fsync(_:)` after
  append-log mutation batches (only `.always`) and checkpoint writes (every policy
  except `.never`). See
  [`Sources/InnoNetworkDownload/InnoNetworkDownload.docc/Articles/Persistence.md`](Sources/InnoNetworkDownload/InnoNetworkDownload.docc/Articles/Persistence.md).

### Deferred to v5

- WebSocket `permessage-deflate` extension (RFC 7692) — requires a
  transport substitution because `URLSessionWebSocketTask` does not
  expose deflate negotiation. The two paths (`InnoNetworkWebSocketNIO`
  product on swift-nio vs `Network.framework` direct implementation)
  are tracked in [`docs/ROADMAP.md`](docs/ROADMAP.md).

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
