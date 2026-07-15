# Roadmap

## Upcoming 5.0.0 Implementation Scope

The unreleased 5.0 preview on `main` converts the hardening backlog into an explicit major-version
contract:

- request execution policies preserve the executor-owned request identity;
- body-aware signing runs after interceptors and refresh-token application and
  signs the exact data or file snapshot sent by the transport;
- signed requests bypass caches/coalescing and reject automatic redirects;
- default redirects deny HTTPS downgrade and unsafe cross-origin replay;
- download and WebSocket shutdown paths have bounded, exactly-once cleanup;
- refresh generations, cache lookup sharing, and circuit-breaker half-open
  hysteresis have deterministic tests;
- release provenance, recursive CycloneDX SBOMs, coverage, release-mode
  benchmarks, and all-product DocC are enforced by CI; and
- explicit endpoint structs become the macro-first catalog shape: the root
  `@APIDefinition` macro derives boilerplate, requires visible response/auth
  intent, and fails closed on unsafe or ambiguous definitions; and
- the seven deprecated configuration modifiers and package-internal reducer
  vocabulary are removed from the public API.

The draft source migration is documented in `docs/Migration-5.0.0.md`. Remaining
items below are either historical context or post-5.0 candidates.

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
- Phantom generic auth markers on `EndpointBuilder` (shipped in 4.x, then
  replaced in 5.0 by explicit `SessionAuthentication` values).

## 4.x Typed-Throws Surface

`NetworkClient.request(_:)`, `request(_:tag:)`,
`request(_:method:tag:)`, `upload(_:)`, and `upload(_:tag:)` now expose
`async throws(NetworkError)`. This shipped in the 4.x public contract and is
unchanged in 5.0. Interceptors and execution policies that
produce arbitrary errors are normalized before they leave the client
surface so callers can switch on `NetworkError` directly.

The previous 5.0 candidate on this axis was not typed throws. The large
`NetworkConfiguration.init(...)` compatibility initializer was removed from
the public API before the 4.0.0 baseline, so 4.x examples and docs should use
`safeDefaults(baseURL:)`, `recommendedForProduction(baseURL:)`,
`advanced(baseURL:resilience:auth:observability:cache:transport:)`, or the
configuration-pack surface.

## 4.x Trust Pinning Module Split (shipped)

The pinning surface — `PublicKeyPinningPolicy`, the SPKI/DER helpers,
and the per-host evaluation logic — moved into a dedicated
`InnoNetworkTrust` companion product so apps that rely on Apple's ATS
defaults (probably 90% of consumers — pinning is operationally heavy
and a common cause of self-inflicted outages when a cert rotates) no
longer pay for the binary or review cost.

What shipped:

- `PublicKeyPinningPolicy`, `PublicKeyPinningPolicy.HostMatchingStrategy`,
  and the new `PublicKeyPinningEvaluator: TrustEvaluating` live in
  `Sources/InnoNetworkTrust/`. Adopters opt in with `import
  InnoNetworkTrust` and feed the evaluator into
  `TrustPolicy.custom(...)`.
- Core `InnoNetwork` keeps `TrustPolicy`, `TrustEvaluating`,
  `TrustFailureReason`, and the new `TrustChallengeOutcome` enum.
  `TrustEvaluating.evaluate(challenge:)` now returns the rich
  `TrustChallengeOutcome` so granular failure reasons (`.pinMismatch`,
  `.hostNotPinned`, `.publicKeyExtractionFailed`,
  `.systemTrustEvaluationFailed`) survive the split without telemetry
  regression.
- `TrustPolicy.publicKeyPinning(_:)` was removed outright. Adopters
  migrate by constructing `PublicKeyPinningEvaluator(policy:)` and
  passing it to `TrustPolicy.custom(_:)`. No re-export shim; the
  hard rename is announced in `CHANGELOG.md`.
- `NetworkConfiguration.trustPolicy` keeps its public type. The
  configuration value continues to flow through the same execution
  pipeline (`RequestExecutionPolicy`, `NetworkObservability`); only
  the declaration site of the pinning evaluator moves.

## 5.0 Body-Aware Reference Signers — AWS SigV4 and JWT Bearer

`HMACRequestInterceptor` remains in the core product. AWS-specific signing
ships in the optional `InnoNetworkAuthAWS` companion product so the first
request path does not imply AWS SDK coverage:

- **AWS SigV4** — `InnoNetworkAuthAWS.AWSSigV4Interceptor` is a
  canonical-request reference signer for AWS APIs and any service that adopts
  the same authorization scheme. It is not an AWS SDK replacement; streaming
  SigV4, presigned URLs, credential-provider chains, and service-specific
  behaviours stay out of scope.
- **JWT Bearer (request-minted)** — interceptor shape for backends that
  expect a JWT computed per request (claims include method/path).
  `RefreshTokenPolicy` already covers session-rotated bearer tokens, so
  this signer targets the request-minted lane only.

Reference signers conform to `RequestSigner` and observe the final
`RequestBody` after request interceptors and refresh-token application. Data
and stable file snapshots are supported; opaque body streams and SigV4
chunk-signing remain explicitly deferred to protocol-specific transports.

## Provisional to Stable Promotion Roadmap

| Surface | Current state | Promotion target | Done criteria |
| --- | --- | --- | --- |
| `EndpointBuilder` runtime-composed path | Stable candidate before 4.0.0 | Stable at 4.0.0 | Runtime-composed request examples and migration cookbook shapes stay green. |
| `InnoNetworkAuthAWS` | Provisionally Stable | 5.x minor after field validation | AWS SigV4 vector tests, README/DocC reference-signer scope, and one adopter migration note. |
| `PersistentResponseCache` telemetry/statistics | Provisionally Stable | 5.x minor | Reentrancy invariant documented, persistent cache tests cover key rotation and stats. |
| `ResponseCachePolicy.rfc9111Compliant(wrapping:)` | Provisionally Stable | 5.x minor | Directive subset is documented as RFC 9111-aware, not full compliance, with cache policy tests. |
| Root `@APIDefinition` macro | Provisionally Stable | No automatic promotion | Explicit structs remain the source of truth; diagnostics, body/query inference, and the core-only trait opt-out sustain adopter validation. |

## Post-5.0 RFC Parking Lot

These are deliberately not implemented in the planned 5.0.0 contract:

- `NetworkConfiguration.Transport`, `.Resilience`, `.Auth`, and
  `.Observability` nested naming can replace the current top-level pack names
  in a later major if adopter feedback shows the flatter names are confusing.
- `NetworkError` can move to a frozen outer wrapper plus an unfrozen inner
  `Reason` in a later major if catch sites need a smaller stable matching
  surface. Until then, the current enum stays the 5.x source shape.

## 5.0 Configuration Contract — Packs over AdvancedBuilder

`NetworkConfiguration` exposes a Packs-only public entry point:

```swift
NetworkConfiguration.advanced(
    baseURL: api,
    resilience: ResiliencePack(retry: ExponentialBackoffRetryPolicy()),
    auth: AuthPack(refreshToken: refresh),
    cache: CachePack(responseCachePolicy: .cacheFirst(maxAge: .seconds(60)))
)
```

Five Pack value types (`ResiliencePack`, `AuthPack`, `ObservabilityPack`,
`CachePack`, `TransportPack`) carry the full configuration surface; the
underlying `AdvancedBuilder` is now `package`-only and unreachable from
client code. The closure-based `advanced(baseURL:_:)` factory was
removed in 4.x; adopters migrate by replacing closure mutations with
the equivalent Pack fields.

## Explicitly Deferred

- Full WebSocket `permessage-deflate` (RFC 7692) negotiation remains out of
  the URLSession product. 4.0.0 now emits a terminal unsupported-feature
  diagnostic when the flag is enabled on URLSession; the natural path for real
  compression is a separate optional transport product with a non-zero
  dependency budget.
- Broader Download side-effect ownership remains out of this PR; Download
  already owns reducer-driven state decisions in 4.0.0.
- An NIO-backed WebSocket/HTTP transport product remains out of this PR so the
  core request product keeps its URLSession-first shape.
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
  richer public HTTPTypes/OpenAPI conversion adapters, external generator
  version pinning, Linux-safe contracts, and iOS 17 LTS evaluation remain
  post-5.0 adoption work rather than GA blockers. The existing
  `InnoNetworkOpenAPI` transport owns a direct compatible 1.x
  `swift-http-types` dependency, currently validated with 1.6.0; the deferred
  item is broader public conversion API, not dependency hygiene at that
  companion boundary.

## Continuing Operations

- Keep benchmark baselines tied to a documented rationale in
  `Benchmarks/Baselines/CHANGELOG.md`.
- Keep `Scripts/check_docs_contract_sync.sh` as the release gate for public
  symbol drift, DocC smoke coverage, and docs/API promises.
- Keep `@unchecked Sendable` out of production sources; test-only exceptions
  should live in test or TestSupport targets.
- Revisit full WebSocket compression and alternate transports only after the
  URLSession-based products have a tagged 5.0.0 baseline.
- Continue hardening persistent cache operations with production feedback on
  eviction policy, data-protection defaults, app-group deployment, and privacy
  header policy.
