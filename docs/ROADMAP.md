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

## 4.x Typed-Throws Surface

`NetworkClient.request(_:)`, `request(_:tag:)`,
`request(_:method:tag:)`, `upload(_:)`, and `upload(_:tag:)` now expose
`async throws(NetworkError)`. This is the 4.x public contract, not a
future 5.0 migration item. Interceptors and execution policies that
produce arbitrary errors are normalized before they leave the client
surface so callers can switch on `NetworkError` directly.

The previous 5.0 candidate on this axis was not typed throws. The large
`NetworkConfiguration.init(...)` compatibility initializer was removed from
the public API before the 4.0.0 baseline, so 4.x examples and docs should use
`safeDefaults(baseURL:)`, `recommendedForProduction(baseURL:)`,
`advanced(baseURL:resilience:auth:observability:cache:transport:)`, or the
pack/fluent modifier surfaces.

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

## 4.x Reference Signers — AWS SigV4 and JWT Bearer

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

Reference signers ride on the existing `RequestInterceptor` contract. Streaming
body variants (SigV4 chunk-signed) are explicitly deferred because the
interceptor surface runs before the upload pipeline owns the body.

## Provisional to Stable Promotion Roadmap

| Surface | Current state | Promotion target | Done criteria |
| --- | --- | --- | --- |
| `EndpointBuilder` onboarding path | Stable candidate before 4.0.0 | Stable at 4.0.0 | README first-30-minute flow, stable example smoke, and migration cookbook examples stay green. |
| `InnoNetworkAuthAWS` | Provisionally Stable | 4.x minor after field validation | AWS SigV4 vector tests, README/DocC reference-signer scope, and one adopter migration note. |
| `PersistentResponseCache` telemetry/statistics | Provisionally Stable | 4.x minor | Reentrancy invariant documented, persistent cache tests cover key rotation and stats. |
| `ResponseCachePolicy.rfc9111Compliant(wrapping:)` | Provisionally Stable | 4.x minor | Directive subset is documented as RFC 9111-aware, not full compliance, with cache policy tests. |
| Macro package | Provisionally Stable | No automatic promotion | Before/after ROI remains clear; deprecate instead of promoting if handwritten endpoints stay simpler. |

## 5.0 RFC Parking Lot

These are deliberately not implemented in the 4.0.0 branch, even though the
branch can still make pre-release breaking changes:

- `NetworkConfiguration.Transport`, `.Resilience`, `.Auth`, and
  `.Observability` nested naming can replace the current top-level pack names
  in 5.0 if adopter feedback shows the flatter names are confusing.
- `NetworkError` can move to a frozen outer wrapper plus an unfrozen inner
  `Reason` in 5.0 if catch sites need a smaller stable matching surface.
  Until then, the current enum stays the 4.x source shape.

## 4.x Configuration Convergence — Packs over AdvancedBuilder

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
