# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and the project follows Semantic Versioning for the public 4.x line.

## [Unreleased]

### Added

- No unreleased entries yet.

### Changed

- No unreleased entries yet.

## [5.0.0]

Major release that completes the pong RTT observability surface started in
4.3 and ships runnable integration samples for the WebSocket / Download
surfaces. The only breaking change is the previously-deferred
`WebSocketEvent.pong` payload addition — every other entry is additive.
See [`MIGRATION_v5.md`](MIGRATION_v5.md) for the `.pong(_:)` switch-update
diff and a tour of the new samples.

### Breaking

- `WebSocketEvent.pong` is now `case pong(WebSocketPongContext)`. The
  payload mirrors the 4.1 `.ping(WebSocketPingContext)` shape and carries
  the same `attemptNumber` + `roundTrip: Duration` values delivered to
  `setOnPongHandler(_:)`. Exhaustive switches over `WebSocketEvent` must
  bind or ignore the associated value (`case .pong(let ctx)` or
  `case .pong(_)`). Existing patterns that did not bind the payload
  (`if case .pong = event { ... }`) continue to compile unchanged.

### Added

- `Examples/WebSocketChat` — runnable CLI sample that connects to a
  public echo server, streams stdin lines as WebSocket messages, and
  exercises the `.pong(_:)` event stream *and* `setOnPongHandler(_:)`
  callback in parallel. Gated behind `INNONETWORK_RUN_INTEGRATION=1` so
  `swift build` stays offline-safe.
- `Examples/DownloadManager` — runnable CLI that drives a real HTTPS
  download through `DownloadManager`, showcasing the 4.3
  `exponentialBackoff` / `retryJitterRatio` / `maxRetryDelay` surface
  and per-percent progress logging. Same env-gated execution model.
- `Examples/EventPolicyObserver` — reference implementations of
  `EventPipelineMetricsReporting` backed by `os.Logger`, `OSSignposter`
  (Points of Interest), and a `CompositeMetricsReporter` fan-out helper.
  No external dependencies; a swift-metrics bridge recipe is included in
  the README as a comment-only snippet.
- `SmokeTests/InnoNetworkDownloadSmoke` — integration smoke exercising
  the real URLSession-backed `DownloadManager.pause` / `resume` path
  end-to-end. Gated behind `INNONETWORK_RUN_INTEGRATION=1`; the offline
  default prints a skip message and exits 0 so the target can ship in
  CI without requiring network access.
- `.github/workflows/tsan.yml` — nightly (+ `workflow_dispatch`) CI job
  that runs the full test suite under ThreadSanitizer on macOS 15.
  Catches races inside URLSession internals and across actor
  boundaries that static strict-concurrency analysis cannot prove safe.

## [4.3.0]

Minor release that promotes round-trip time to a first-class observability
surface, adds opt-in exponential backoff to the Download module, and
completes the stub-based deterministic test migration for
`DownloadManager`. See [`MIGRATION_v4.3.md`](MIGRATION_v4.3.md) for
optional pong RTT adoption guidance.

### Added

- `WebSocketPongContext` carries `attemptNumber` (matches the paired
  `WebSocketPingContext.attemptNumber`) and `roundTrip: Duration`
  (computed by the library as
  `ContinuousClock.now - pingContext.dispatchedAt` just before `.pong`
  publish time).
- `WebSocketManager.setOnPongHandler(_:)` delivers
  `WebSocketPongContext` for successful pongs without changing existing
  `.pong` event handling. Consumers can adopt library-computed RTT
  incrementally while keeping `case .pong:` switches source-compatible.
- `DownloadConfiguration.exponentialBackoff` (default `false`),
  `retryJitterRatio` (default `0.2`), and `maxRetryDelay` (default
  `60s`, `<= 0` disables the user-facing cap). Opt-in so 4.x retains
  the existing fixed-delay retry behavior; enabling computes a
  `retryDelay * 2^(retryCount - 1)` base delay and samples the final
  wait from `base ± (base * retryJitterRatio)`, clamped to
  `maxRetryDelay` when active and always bounded to a runtime-safe
  maximum sleep duration.
- Swift 6.2+ language-mode audit note at
  [`docs/SwiftLanguageMode.md`](docs/SwiftLanguageMode.md) — records
  which features (`InlineArray`, `Span`, `@concurrent`, task-local
  values) were evaluated for this release and why the production source
  was not changed.

### Changed

- Download pause/resume/restore tests migrated to the
  `StubDownloadURLSession` harness introduced in 4.2. Real-URLSession
  integration races and wall-clock polling are gone from these suites.
  `InMemoryDownloadTaskStore` was promoted to a shared test-internal
  helper so the retry / retry-timing / pause-resume / restore suites
  all share one store implementation.
- `StubDownloadURLSession` gains `preinstall(_:)` so restore tests can
  surface tasks to the restore coordinator without going through
  `makeDownloadTask(...)`.
- WebSocket receive-loop test suite expanded with burst-delivery and
  URL-task-swap edge-case coverage.

## [4.2.0]

Minor release that adds a reconnect-delay cap, a reusable test-support
target, deterministic download retry tests, and DocC coverage for the
shared event-delivery policy.

### Added

- `WebSocketConfiguration.maxReconnectDelay` — caps the exponential
  backoff delay when set to a positive value. The default remains
  disabled (`0`), preserving the pre-4.2 unbounded behavior for existing
  call sites. When enabled, the randomized delay is sampled from a
  bounded range that never exceeds the configured ceiling.
- DocC article **Event delivery policy** documenting
  `EventDeliveryPolicy` tuning — per-partition / per-consumer buffering,
  `.dropOldest` vs `.dropNewest` selection, metrics reporter
  integration, and aggregate snapshot interpretation. Linked from core
  as well as the Download and WebSocket modules.

### Changed

- Download retry tests now run against a new `StubDownloadURLSession`
  harness instead of a live `URLSession` with an `.invalid` URL. The
  retry chain is driven by injected synthetic completions, so full-suite
  execution is deterministic and no longer relies on wall-clock polling.
  The suite runs serialized (`@Suite(.serialized)`) to keep multi-step
  retry cascades robust under cooperative pool contention.
- Test-only: the `HeartbeatEventRecorder` alias is **removed**. Tests
  now use `WebSocketEventRecorder` directly. The type was internal to
  the WebSocket test target only — not a public API change.
- Test-only: `TestClock` no longer ships as three hand-maintained
  copies. A new package-internal `InnoNetworkTestSupport` target hosts
  `TestClock` and `WebSocketEventRecorder` and is imported by all three
  test targets. The target is **not** exposed as a `.library` product,
  so external consumers never see these helpers. The old
  `Scripts/verify_testclock_parity.sh` parity guard is deleted.
- CI: the `@unchecked Sendable` prohibition is now scoped to the three
  shipping library targets so the `InnoNetworkTestSupport` helpers can
  use `@unchecked Sendable` where warranted (e.g. `TestClock`).

## [4.1.0]

Minor release that adds two public observability surfaces on top of 4.0 —
both are additive. See [`MIGRATION_v4.1.md`](MIGRATION_v4.1.md) for call-site
guidance on the `WebSocketEvent.ping` associated-value change.

### Added

- `WebSocketCloseDisposition` is now a public enum. Consumers can observe
  the library's close classification via the new
  `WebSocketTask.closeDisposition` property and branch their own UX on
  `peerRetryable` / `peerTerminal` / `handshakeTimeout` / etc. without
  re-implementing the mapping. The classifier factories
  (`classifyPeerClose`, `classifyHandshake`) stay package-scoped — the
  policy is still library-owned.
- `WebSocketPingContext` carries `attemptNumber` (monotonic within the
  current connection) and `dispatchedAt` (`ContinuousClock.Instant`) so
  consumers can compute per-cycle round-trip time by pairing each
  `.ping(_:)` event with its matching `.pong`.

### Changed

- **BREAKING (minor)**: `WebSocketEvent.ping` now carries a
  `WebSocketPingContext` associated value. The case name is unchanged;
  exhaustive switches must update `case .ping:` to `case .ping(_):` (or
  pattern-bind the context). Pattern matches that already used
  `if case .ping = event` keep compiling untouched.
- Consumer smoke now compiles against the 4.0/4.1 WebSocket public surface,
  and benchmark automation runs websocket quick benchmarks in CI with a
  coarse PR smoke threshold plus a stricter scheduled/manual regression gate.

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
