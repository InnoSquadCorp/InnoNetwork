# Roadmap

## 4.0.0 Implementation Scope

The 4.0.0 improvement PR folds the former minor and major-candidate backlog
into one release line:

- Download restoration contract alignment, including public
  `waitForRestoration()`, observable missing-task failures, foreign-task
  cancellation, and durable paused resume data.
- Download append-log compaction policy and an RFC for checksum, checkpoint,
  disk-full, and app-update recovery behavior.
- DocC smoke coverage for Download and WebSocket article examples.
- Benchmark trend automation with PR-comment rendering, JSONL trend storage,
  and baseline-rationale documentation.
- `URLQueryArrayEncodingStrategy` for indexed, bracketed, and repeated-key
  provider conventions.
- `WebSocketManager.shared` removal in favor of feature-scoped manager
  instances.
- Streaming-by-default inline transport through `bytes(for:)` and
  `ResponseBodyBufferingPolicy`.
- Public `RequestExecutionPolicy` extension points for custom transport-attempt
  policies.
- Shared `StateReducer` / `StateReduction` vocabulary plus reducer-driven
  Download and WebSocket lifecycle decisions.
- New `InnoNetworkPersistentCache` companion product.
- Compile-time macro diagnostics for optional path placeholders.
- Phantom auth scopes through `EndpointAuthScope`, `PublicAuthScope`,
  `AuthRequiredScope`, and `AuthenticatedEndpoint`.

## Explicitly Deferred

- WebSocket `permessage-deflate` (RFC 7692) remains out of this PR.
  `URLSessionWebSocketTask` does not expose deflate negotiation, so the
  natural path is a separate optional transport product with a non-zero
  dependency budget.
- Refresh lifecycle reducer expansion and broader Download side-effect
  ownership remain out of this PR; Download already owns reducer-driven state
  decisions in 4.0.0.
- An NIO-backed WebSocket/HTTP transport product remains out of this PR so the
  root runtime products keep their zero-dependency shape.
- Pulse/Sentry/OpenTelemetry adapter examples remain separate companion
  examples rather than core dependencies.
- Streaming multipart response decoding remains a separate design item; 4.0.0
  keeps `MultipartResponseDecoder` buffered.
- Hummingbird or other server-side Swift in-process integration tests stay out
  of the Apple-client validation matrix.

## Continuing Operations

- Keep benchmark baselines tied to a documented rationale in
  `Benchmarks/Baselines/CHANGELOG.md`.
- Keep `Scripts/check_docs_contract_sync.sh` as the release gate for public
  symbol drift, DocC smoke coverage, and docs/API promises.
- Keep `@unchecked Sendable` out of production sources; test-only exceptions
  should live in test or TestSupport targets.
- Revisit WebSocket compression and alternate transports only after the
  URLSession-based products have a tagged 4.0.0 baseline.
- Continue hardening persistent cache operations with production feedback on
  eviction policy, data-protection defaults, app-group deployment, and privacy
  header policy.
