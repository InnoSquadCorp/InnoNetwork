# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and the project follows Semantic
Versioning.

## [Unreleased]

## [5.0.0] - 2026-07-14

### Breaking

- `RequestExecutionNext.execute(_:)` is replaced by
  `RequestExecutionNext.execute()`. Request mutation belongs in a
  `RequestInterceptor`; execution policies can observe, short-circuit, or
  replay only the executor-owned request.
- The seven deprecated `NetworkConfiguration.with(...)` modifiers are removed.
  Compose `ResiliencePack`, `AuthPack`, `ObservabilityPack`, `CachePack`, and
  `TransportPack` through `NetworkConfiguration.advanced(...)`.
- `StateReducer` and `StateReduction` are package implementation vocabulary,
  not public API. Adopters should own reducer types at their feature boundary.
- Redirect defaults deny HTTPS downgrade and unsafe cross-origin `307`/`308`
  replay. Signed requests reject every automatic redirect.
- Body-dependent authentication uses `RequestSigner` and `RequestBody` after
  interceptors and refresh-token application. Signed requests bypass response
  caches, request coalescing, and URLSession cache storage.
- `WebSocketManager.retry(_:)` returns an optional fresh `WebSocketTask` with a
  new ID. The source task stays terminal, and per-task consumers must attach to
  the returned replacement; automatic reconnect still preserves its task ID.

See [`docs/Migration-5.0.0.md`](docs/Migration-5.0.0.md) for before/after
examples and [`docs/releases/5.0.0.md`](docs/releases/5.0.0.md) for the
curated release summary.

### Added

- `RequestSigner` and `RequestBody` provide late, body-aware authentication
  after request encoding, interceptors, and refresh-token application. The
  HMAC, request-minted JWT, and AWS SigV4 reference implementations support
  stable data and file payloads through this contract.
- Release provenance validation now requires annotated unprefixed SemVer tags
  on `origin/main`, deterministic root and codegen CycloneDX 1.5 SBOMs, and
  signed benchmark/SBOM release artifacts.
- CI builds DocC for all eight public products and fails closed when core or
  codegen coverage artifacts are missing, empty, or contain absolute
  source paths.

### Fixed

- Download completion staging, pause/resume transactions, temporary-file
  cleanup, and shutdown behavior are bounded and cancellation-safe.
- WebSocket disconnect and shutdown teardown are bounded. The final terminal
  outcome is forced into every snapshotted consumer queue even under
  `.dropNewest` saturation, then the partition and registry close before
  snapshotted manager callbacks run.
- WebSocket reconnect-budget exhaustion emits one authoritative public error,
  and pong publication is attempted before its snapshotted manager handler;
  ordinary overflow and asynchronous listener delivery still apply.
- Refresh generations, transient persistent-cache key reads, shared cache
  lookups, and circuit-breaker half-open hysteresis preserve their state under
  cancellation and concurrent replay.

### Changed

- `APISingleRequestExecutable` snapshots its transport policy once so request
  encoding and decoding observe one policy value.
- Scheduler-sensitive cancellation, refresh, and WebSocket tests use explicit
  gates; CI runs the complete root suite in both serial coverage and parallel
  modes.
- External WebSocket shutdown waits for already-admitted manager callbacks;
  reentrant shutdown from one of those callbacks initiates teardown and returns
  so a later external call can await the full boundary.
- Guarded benchmarks build in release mode, and 5.0 publishes an explicit API,
  migration, codegen-distribution, and release-integrity contract.

## [4.0.0] - 2026-05-02

InnoNetwork's first public release. The detailed 4.0.0 changelog has
been archived to [`docs/releases/4.0.0.md`](docs/releases/4.0.0.md) —
that document carries the curated release notes (originally a
one-pager) together with the full per-line CHANGELOG section that
previously lived here, plus the 49-item hardening coverage table and
release-quality matrix. The migration guide at
[`docs/Migration-4.0.0.md`](docs/Migration-4.0.0.md) remains the entry
point for upgrade work.

This `CHANGELOG.md` retains only the `Unreleased` window and the
archive pointers below; older releases (when they exist) follow the
same pattern.

### Older releases

Per-version detail is captured under [`docs/releases/`](docs/releases/).
The current archive is [`4.0.0.md`](docs/releases/4.0.0.md).
