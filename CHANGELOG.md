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
- The raw-string `NetworkClient.request(_:method:tag:)` convenience is removed.
  Use a named macro-assisted or manual `APIDefinition` for catalog requests, or
  an `EndpointBuilder` with an explicit authentication choice for one-off and
  runtime-composed requests.
- `NetworkConfiguration.responseBodyLimit` is removed. Configure collection
  mode and its optional byte ceiling together with
  `ResponseBodyBufferingPolicy.streaming(maxBytes:)` or
  `.buffered(maxBytes:)`.
- The no-op
  `WebSocketManager.handleBackgroundSessionCompletion(_:completion:)` method
  is removed. WebSockets do not use Foundation background sessions; route
  download callbacks to `DownloadManager` and complete unrelated identifiers
  at the application boundary.
- `WebSocketConfiguration.sessionIdentifier` and the matching advanced
  builder field are removed. The value was never applied to the default
  foreground `URLSession` used by WebSockets and provided no isolation or
  restoration semantics.
- `DownloadConfiguration.default` and `WebSocketConfiguration.default` are
  removed because they duplicate `safeDefaults()`. Use the named factory when
  passing a configuration explicitly; `DownloadManager()` and
  `WebSocketManager()` keep their zero-argument defaults.
- `DownloadManager.make(configuration:)` is removed because it exactly
  forwards to the public throwing initializer. Use
  `DownloadManager(configuration:)` as the single construction path.
- `PersistentResponseCacheStatistics` construction is package-owned. Obtain
  authoritative snapshots from `await cache.statistics()`; the public
  properties remain readable for dashboards and back-pressure decisions.
- The direct 21-parameter `WebSocketConfiguration` initializer is
  package-owned. Use `safeDefaults()` for the secure preset or `advanced(_:)`
  for explicit tuning.
- `WebSocketTask` construction is package-owned. Obtain handles from
  `WebSocketManager.connect(url:subprotocols:)` or an accepted explicit retry
  so every task is registered with its owning manager.
- `HTTPMethod` is now an extensible, `RawRepresentable` value type. Standard
  methods remain static constants; custom methods use the failable
  `init(rawValue:)`, which accepts only nonempty RFC 9110 tokens. Code that
  exhaustively switched over the former enum must use semantic helpers or a
  default branch. Retry, redirect, cache, coalescing, and curl diagnostics
  preserve exact method-token case. URLSession-backed entry points fail before
  transport when Foundation would silently rewrite the requested spelling.
- `RequestExecutionNext.execute(_:)` is replaced by
  `RequestExecutionNext.execute()`. Request mutation belongs in a
  `RequestInterceptor`; execution policies can observe, short-circuit, or
  replay only the executor-owned request.
- The seven deprecated `NetworkConfiguration.with(...)` modifiers are removed.
  Compose `ResiliencePack`, `AuthPack`, `ObservabilityPack`, `CachePack`, and
  `TransportPack` through `NetworkConfiguration.advanced(...)`.
- `StateReducer` and `StateReduction` are package implementation vocabulary,
  not public API. Adopters should own reducer types at their feature boundary.
- Redirect defaults deny HTTPS downgrade and every cross-origin proposal that
  retains an unsafe method. Other cross-origin hops strip every caller-prepared
  original header plus built-in and configured sensitive session headers.
  Signed requests reject every automatic redirect.
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
- Download presets now use secure foreground sessions. Process-independent
  continuation is the explicit `backgroundTransfersEnabled()` opt-in, and
  `DownloadTask` construction is manager-owned rather than publicly
  fabricatable. The direct 22-parameter `DownloadConfiguration` initializer is
  package-owned; use `safeDefaults(sessionIdentifier:)` or
  `advanced(sessionIdentifier:_:)`.

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
  deployment floors as required gates. Every independent example manifest is
  checked against the same floors, its consumer smoke target builds on the
  host, generalized macro compile-failure fixtures run, and dependency review
  failures remain fail-closed in the workflow.
- The root `Package.resolved` is tracked as the repository's reproducible
  dependency input. CI rejects lock drift and deletion/untracked recreation;
  independent example and tool lock files remain ignored. Main and PR
  dependency submission now share a strict `Package.resolved` converter, and
  every `main` SHA receives a baseline snapshot while release CycloneDX
  generation remains independent. A privileged
  `workflow_run` follow-up checks out only trusted main code, reads the exact PR
  head lockfile as bounded data, and never executes PR code; this also covers
  Dependabot without granting the ordinary PR workflow write access. The
  read-only `Dependency Review` job requires a present, empty snapshot-warning
  header before review, so a missing Swift snapshot can no longer pass as an
  empty false green. Same-version revision substitutions are rejected before
  submission instead of disappearing from the version-based dependency diff.

### Fixed

- `@APIDefinition` path placeholders whose property typealiases resolve to
  Optional now fail with targeted unwrap-and-define-nil-behavior guidance
  instead of exposing the generated path encoder's generic constraint error.
- Core URLSession transports now suppress every
  `URLSessionConfiguration.httpAdditionalHeaders` value on cross-origin
  redirects. Foundation otherwise re-injected session defaults after the
  redirect policy removed them; same-origin redirects continue to receive the
  configured values.
- `InnoNetworkClientTransport` now applies the default redirect policy and URL
  admission to every generated-client redirect hop, strips caller-prepared
  headers and clears session-configured header values across origins, rejects
  unsafe cross-origin replay and HTTPS downgrade, and refuses background
  URLSession instances whose redirects Foundation does not expose to the task
  delegate.
- Persistent-cache index reads are capped at 16 MiB before JSON decoding;
  oversized indexes now cold-reset only cache-owned state instead of allowing
  unbounded initialization memory growth.
- Download persistence now anchors its owned root and session with directory
  file descriptors and performs lock, checkpoint, append-log, temporary, and
  quarantine operations through `openat`-family calls with no-follow and inode
  checks. Pre-existing managed-file symlinks, hard links, and FIFOs are rejected,
  while replacing the visible session parent cannot redirect metadata I/O outside
  the retained directory descriptor. The boundary assumes one cooperating owner;
  a caller-provided base path remains the explicitly trusted, canonicalized anchor.
- Download persistence now distinguishes malformed bytes from storage-access
  failures. Data Protection, permission, lock, and transient I/O errors fail
  initialization without quarantining valid state, while corrupt append-log
  recovery durably commits the valid prefix before moving or resetting the
  authoritative log.
- Persistent response-cache initialization now treats only a missing index as
  empty and resets only successfully read malformed or unsupported index data.
  Index symlinks, directories, FIFOs, and other non-regular entries are rejected
  without following or blocking on them.
  Protected-data, permission, and transient I/O failures preserve index/body
  files and fail initialization; transient live body reads return a miss while
  retaining the entry for a later retry.
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
- `InnoNetworkTestSupport`'s `MockURLSession` and VCR replay mode remain
  compatible with the bounded `safeDefaults` profile. Their already-buffered
  fixtures are rejected at the transport boundary before response events,
  execution-policy response handling, auth refresh, cache, or interceptors.
  VCR record mode and arbitrary custom sessions without streaming support fail
  closed under bounded streaming policies.
- OpenAPI transport treats HEAD responses, successful CONNECT `2xx`,
  informational `1xx`, and statuses `204`, `205`, and `304` as bodyless, while
  preserving base paths and query ordering when adapting requests.
- WebSocket handshake redirects now pass through per-hop URL admission. Secure
  handshakes cannot downgrade to plain WS, traversal targets fail terminally
  without reconnect, and cross-origin redirects strip every caller-prepared
  header plus built-in credential fields while preserving CFNetwork's required
  handshake and subprotocol negotiation fields. The credential boundary stays
  fixed to the original handshake origin across multi-hop redirects.
- Curl export and observability redact query values, request bodies, URL
  credentials, fragments, sensitive path tokens, and error payload details by
  default. Controlled debugging can opt into query values or bodies explicitly.
- Persistent cache and download-owned state apply backup exclusion on Darwin
  after directory creation, atomic replacement, and reopen. On iOS, tvOS,
  watchOS, and visionOS they also apply
  `.completeUntilFirstUserAuthentication` Data Protection. Caller-owned final
  download files are not relabeled.
- Download persistence and completion staging no longer use a path-like,
  uppercase, oversized, empty, or non-ASCII `sessionIdentifier` as a raw path
  component. Those identifiers map to one deterministic SHA-256 component,
  preventing case-insensitive filesystem aliases, while conventional lowercase
  reverse-DNS identifiers keep their existing layout and Foundation still
  receives the original value.
- Download completion staging, pause/resume transactions, temporary-file
  cleanup, and shutdown behavior are bounded and cancellation-safe.
- WebSocket disconnect and shutdown teardown are bounded. The final terminal
  outcome is forced into every snapshotted consumer queue even under
  `.dropNewest` saturation, then the partition and registry close before
  snapshotted manager callbacks run.
- WebSocket reconnect-budget exhaustion emits one authoritative public error,
  and pong publication is attempted before its snapshotted manager handler;
  ordinary overflow and asynchronous listener delivery still apply.
- Refresh generations, shared cache lookups, and circuit-breaker half-open
  hysteresis preserve their state under cancellation and concurrent replay.
- Request event partitions preserve terminal events already queued behind a
  slow observer. Finish waits for partition-to-observer handoff without making
  request completion depend on observer handler latency.

### Changed

- `InnoNetworkOpenAPI` declares its direct `swift-http-types` dependency with a
  compatible 1.x range from 1.6.0 instead of relying on
  `swift-openapi-runtime` to expose it transitively. The floor matches OpenAPI
  Runtime 1.12's use of the `FoundationURL` trait. HTTPTypes remains confined
  to the optional `InnoNetworkOpenAPI` boundary; the core `InnoNetwork` public
  request, header, and response models do not expose it.
- Response-cache keys preserve query-item ordering, and persistent cache format
  version 4 HMAC-protects the complete raw query while retaining that ordering
  in the digest input. Version-3-or-older indexes cold-reset so legacy raw query
  material is not retained.
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
