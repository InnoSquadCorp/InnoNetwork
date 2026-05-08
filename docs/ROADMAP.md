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
  Download, WebSocket, and refresh-token lifecycle decisions.
- `InnoNetworkPersistentCache` companion product with HMAC disk keys, App Group
  directory helper, statistics, and scrub/eviction telemetry.
- `MultipartStreamingResponseDecoder` for large multipart response streams.
- `InnoNetworkOpenAPI` companion product and VCR-style test support helpers.
- Compile-time macro diagnostics for optional path placeholders.
- Phantom auth scopes through `AuthScope`, `PublicAuthScope`,
  `AuthRequiredScope`, and `EndpointBuilder`.

## 4.x Configuration Convergence — Packs over AdvancedBuilder

`NetworkConfiguration.AdvancedBuilder` exposes 33 mutable fields for
backwards compatibility with the 3.x configuration shape. Five
`Configuration*Pack` value types (`ResiliencePack`, `AuthPack`,
`ObservabilityPack`, `CachePack`, `TransportPack`) ship alongside as
forward-compat building blocks; they currently apply themselves to a
builder via `apply(to:)`, so today they are syntactic sugar over the
flat builder rather than an independent configuration model.

The 4.x line **prefers Packs as the documented entry point** and treats
the flat builder as a legacy ramp:

- New code, examples, and DocC tutorials should compose configurations
  out of Packs (`NetworkConfiguration.advanced(baseURL:) { builder in
  ResiliencePack(...).apply(to: &builder); AuthPack(...).apply(to: &builder)
  }`) rather than mutating the builder directly.
- `AdvancedBuilder` itself is **not** marked `@available(*, deprecated)`
  in 4.x; doing so today would warn on every Pack `apply(to:)` call
  because Packs internally mutate the same builder. The convergence
  plan is to introduce a Packs-only configuration init in a later 4.x
  minor (no major bump), once each axis has a dedicated Pack and the
  builder can be retired without losing expressiveness.
- Adopters who only mutate a handful of fields can keep using the
  builder; the targeted `@available(*, deprecated)` pass will land
  alongside the Packs-only init.

This is a documentation-level commitment, not a contract change.
`API_STABILITY.md` continues to list the builder as part of the
Provisionally Stable surface so existing call sites compile without
changes for the rest of the 4.x line.

## Explicitly Deferred

- Full WebSocket `permessage-deflate` (RFC 7692) negotiation remains out of
  the URLSession product. 4.0.0 now emits a terminal unsupported-feature
  diagnostic when the flag is enabled on URLSession; the natural path for real
  compression is a separate optional transport product with a non-zero
  dependency budget.
- Broader Download side-effect ownership remains out of this PR; Download
  already owns reducer-driven state decisions in 4.0.0.
- An NIO-backed WebSocket/HTTP transport product remains out of this PR so the
  root runtime products keep their zero-dependency shape.
- Pulse/Sentry/OpenTelemetry adapter examples remain separate companion
  examples rather than core dependencies.
- Hummingbird or other server-side Swift in-process integration tests stay out
  of the Apple-client validation matrix.
- Full `StreamingRetryPolicy` beyond Last-Event-ID resume remains deferred.
  4.0.0 adds bounded output buffering but does not make arbitrary streams
  replayable.
- Multiple refresh-policy chains are deferred. 4.0.0 adds
  `RefreshTokenPolicy.appliesTo` for request-level routing while keeping one
  coordinator per client configuration.
- Header/query result-builder DSLs, mutation testing, full SwiftUI sample app,
  richer HTTPTypes/OpenAPI adapters that pin external generator versions,
  Linux-safe contracts, and iOS 17 LTS evaluation remain post-4.0 adoption work
  rather than GA blockers.

## Continuing Operations

- Keep benchmark baselines tied to a documented rationale in
  `Benchmarks/Baselines/CHANGELOG.md`.
- Keep `Scripts/check_docs_contract_sync.sh` as the release gate for public
  symbol drift, DocC smoke coverage, and docs/API promises.
- Keep `@unchecked Sendable` out of production sources; test-only exceptions
  should live in test or TestSupport targets.
- Revisit full WebSocket compression and alternate transports only after the
  URLSession-based products have a tagged 4.0.0 baseline.
- Continue hardening persistent cache operations with production feedback on
  eviction policy, data-protection defaults, app-group deployment, and privacy
  header policy.
