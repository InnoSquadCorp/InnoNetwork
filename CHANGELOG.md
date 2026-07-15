# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and the project follows Semantic
Versioning.

## [Unreleased]

`main` is the source-breaking 5.0 preview. These changes have not been tagged
or released as `5.0.0`; `4.0.0` remains the latest tagged stable release.

### Breaking

- The nested `Packages/InnoNetworkCodegen` package and `#endpoint` expression
  macro are removed. `@APIDefinition(method:path:auth:)` now comes from
  `import InnoNetwork`, requires an explicit `.anonymous` / `.optional` /
  `.required` `SessionAuthentication` choice, and requires
  `typealias APIResponse` on the annotated struct.
- Every buffered, multipart, streaming, OpenAPI, and macro-assisted endpoint
  now carries explicit `SessionAuthentication`. `.required` fails before
  transport if no refresh policy or usable token is available; manual endpoint
  definitions and generated execution adapters no longer inherit anonymous
  authentication implicitly.
- Public optional overloads of
  `EndpointPathEncoding.percentEncodedSegment(_:)` are removed. Unwrap optional
  path values and define their nil behavior before encoding.
- `HTTPMethod` is now an extensible, `RawRepresentable` value type. Standard
  methods remain static constants; custom methods use the failable
  `init(rawValue:)`, which accepts only nonempty RFC 9110 tokens. Code that
  exhaustively switched over the former enum must use semantic helpers or a
  default branch.
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
- Core, OpenAPI, download, and WebSocket entry points reject malformed,
  origin-changing, traversal-bearing, or insecure absolute URLs by default.
  Plain HTTP and WebSocket connections require their explicit configuration
  opt-ins.
- Body-dependent authentication uses `RequestSigner` and `RequestBody` after
  interceptors and refresh-token application. Signed requests bypass response
  caches, request coalescing, and URLSession cache storage.
- `WebSocketHandshakeRequestAdapter.adapt(_:)` is `async throws`; connection
  setup awaits adapter completion and revalidates the resulting request before
  opening a transport.
- `WebSocketManager.retry(_:)` returns an optional `WebSocketRetryResult` with
  a fresh task and bounded event stream. The stream is registered before the
  replacement transport resumes, the source task stays terminal, and automatic
  reconnect still preserves its task ID.

See [`docs/Migration-5.0.0.md`](docs/Migration-5.0.0.md) for before/after
examples and [`docs/releases/5.0.0.md`](docs/releases/5.0.0.md) for the
draft release summary.

### Added

- The root package's default `Macros` trait enables macro-assisted explicit
  endpoint structs. GET/HEAD `query` and POST/PUT/PATCH/DELETE `body` stored
  properties derive payload witnesses, while a complete manual `Parameter` +
  `parameters` pair remains authoritative. Fail-closed diagnostics reject
  incomplete, unsafe, traversal-bearing, or ambiguous declarations, and reject
  custom-method simple payload inference.
- Macro expansion is covered by an end-to-end test that executes the generated
  endpoint through `DefaultNetworkClient`, including path substitution, query
  encoding, explicit authentication, and response decoding.
- `RequestSigner` and `RequestBody` provide late, body-aware authentication
  after request encoding, interceptors, and refresh-token application. The
  HMAC, request-minted JWT, and AWS SigV4 reference implementations support
  stable data and file payloads through this contract.
- Release provenance validation now requires annotated unprefixed SemVer tags
  on `origin/main`, deterministic default-trait and core-only CycloneDX 1.5
  SBOMs, and signed benchmark/SBOM release artifacts.
- CI builds DocC for all eight public products and fails closed when core or
  macro coverage artifacts are missing, empty, or contain absolute
  source paths.
- CI and release validation now cross-compile every public library product for
  the declared tvOS, watchOS, and visionOS device SDKs at the package's
  deployment floors as required gates, compile consumer fixtures at those
  floors, run generalized macro compile-failure fixtures, and treat dependency
  review failures as blocking.

### Fixed

- The API stability contract now classifies core `HTTPMethod` and
  `SessionAuthentication` as Stable only, and keeps Stable and Provisionally
  Stable code spans disjoint so symbols cannot silently receive contradictory
  5.x compatibility promises.
- `NetworkMonitor` now keeps `NWPathMonitor` actor-isolated instead of relying
  on its newer OS-only `Sendable` conformance, preserving clean compilation at
  the declared iOS 16, tvOS 16, and watchOS 9 deployment floors.
- Inline response collection through `safeDefaults`, the `advanced` preset,
  and `recommendedForProduction` is bounded to 5 MiB by default. Explicit
  `.streaming(maxBytes: nil)` or `.buffered(maxBytes: nil)` remains the
  deliberate unbounded opt-out, and byte-count arithmetic fails closed on
  overflow.
- OpenAPI transport treats HEAD responses, informational 1xx responses, and
  statuses 204, 205, and 304 as bodyless, while preserving base paths and query
  ordering when adapting requests.
- Curl export and observability redact query values, request bodies, URL
  credentials, fragments, sensitive path tokens, and error payload details by
  default. Controlled debugging can opt into query values or bodies explicitly.
- Persistent cache and download-owned state apply backup exclusion on Darwin
  after directory creation, atomic replacement, and reopen. On iOS, tvOS,
  watchOS, and visionOS they also apply
  `.completeUntilFirstUserAuthentication` Data Protection. Caller-owned final
  download files are not relabeled.
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
- Request event partitions preserve terminal events already queued behind a
  slow observer. Finish waits for partition-to-observer handoff without making
  request completion depend on observer handler latency.

### Changed

- `InnoNetworkOpenAPI` declares its direct `swift-http-types` dependency with a
  compatible 1.x range from 1.5.1 instead of relying on
  `swift-openapi-runtime` to expose it transitively. HTTPTypes remains confined
  to the optional `InnoNetworkOpenAPI` boundary; the core `InnoNetwork` public
  request, header, and response models do not expose it.
- Response-cache keys preserve query-item ordering, and the persistent cache
  format advances to version 3 so older keys are reset rather than reused with
  incompatible semantics.
- `APISingleRequestExecutable` snapshots its transport policy once so request
  encoding and decoding observe one policy value.
- Scheduler-sensitive cancellation, refresh, and WebSocket tests use explicit
  gates; CI runs the complete root suite in serial coverage mode and across
  four bounded target shards.
- External WebSocket shutdown waits for already-admitted manager callbacks;
  reentrant shutdown from one of those callbacks initiates teardown and returns
  so a later external call can await the full boundary.
- Guarded benchmarks build in release mode, and the 5.0 preview prepares an
  explicit API, migration, macro-trait, and release-integrity contract.
- Hosted benchmark baselines are recalibrated from a complete release-mode
  artifact after the systematic shift was confirmed across three successful
  runs, so debug-build overhead no longer distorts regression deltas.
- CI installs checksum-pinned Periphery and Codecov CLI releases, isolates
  Codecov OIDC to artifact-only upload jobs, bounds concurrent tests to four
  serial target shards, and skips only hosted platform components that the
  pinned runner does not install.
- Periphery now analyzes test-target references instead of baselining package
  test seams. Fourteen unused internal helpers are removed, 40 stale baseline
  entries are pruned, and seven protocol-shape or synthesized-`Equatable`
  analyzer false positives are added explicitly.

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
