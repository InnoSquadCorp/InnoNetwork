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

## 4.x → 5.x Typed-Throws Migration

`NetworkClient.request(_:)`, `request(_:tag:)`, `upload(_:)`, and
`upload(_:tag:)` are declared with untyped `async throws` today.
Callers have to `catch let error as NetworkError` to recover the
typed surface, which works but defeats one of the bigger ergonomic
wins of Swift 6's `throws(MyError)` form (the compiler statically
guarantees the catch covers every case).

A drop-in switch to `throws(NetworkError)` is **not** safe inside the
4.x line:

- Adding a parallel `throws(NetworkError)` overload alongside the
  untyped `throws` overload runs into Swift's typed-throws overload
  resolution: the two signatures differ only in the throws clause and
  cannot coexist as a clean public API.
- Replacing the untyped throws clause with `throws(NetworkError)` is
  a breaking change; every callsite that previously threw a non-
  `NetworkError` type from inside a `RequestInterceptor` would stop
  compiling. That is exactly the kind of change the API_STABILITY
  ledger reserves for a major bump.
- A renamed surface (`requestStrict`, `tryRequest`, …) would mean
  carrying two parallel method names through 4.x; the readability
  loss outweighs the ergonomic gain.

The migration target is the 5.0 major. Until then the public surface
keeps untyped `async throws` and adopters that want the typed surface
can wrap with their own helper:

```swift
extension NetworkClient {
    func requestTyped<T: APIDefinition>(_ request: T) async throws(NetworkError) -> T.APIResponse {
        do { return try await self.request(request) }
        catch let error as NetworkError { throw error }
        catch {
            throw NetworkError.underlying(
                SendableUnderlyingError(domain: "AppDomain", code: -1,
                                        message: String(describing: error)),
                nil
            )
        }
    }
}
```

The 5.0 plan is to flip the protocol declarations to
`throws(NetworkError)` once interceptors are documented as required to
throw `NetworkError` (or to wrap their own errors before exiting the
interceptor chain). The CHANGELOG entry that introduces 5.0 will spell
out the catch-block migration.

## 4.x Trust Pinning Module Split

`TrustPolicy.swift` (~376 lines) and the seven-case `TrustFailureReason`
enum cover certificate pinning, public-key pinning, and custom trust
evaluation. Every adopter pays the binary and review cost of that
surface today, even apps that are happy with Apple's ATS defaults
(probably 90% of consumers — pinning is operationally heavy and a
common cause of self-inflicted outages when a cert rotates).

The 4.x roadmap moves the trust surface into a dedicated
`InnoNetworkTrust` companion product so the cost is opt-in:

- `TrustPolicy`, `TrustFailureReason`, and the underlying evaluator
  move into `Sources/InnoNetworkTrust/`. Adopters who want pinning
  add the new product alongside `InnoNetwork` and `import
  InnoNetworkTrust`.
- The current `InnoNetwork` re-exports the symbols (`@_exported import
  InnoNetworkTrust`) for the first 4.x minor after the split so
  existing call sites keep compiling without import changes; the
  re-export is `@available(*, deprecated, renamed: "InnoNetworkTrust")`
  so adopters get a heads-up to migrate their imports.
- `NetworkConfiguration.trustPolicy` keeps its public type. The
  configuration value continues to flow through the same execution
  pipeline (`RequestExecutionPolicy`, `NetworkObservability`); only
  the declaration site moves.
- Apps that only need ATS get the surface reduction without any
  source change because they never touched the trust types.

Lift-and-shift carries 23 internal call sites today, plus the public
ledger entries in `API_STABILITY.md` and the `TrustPolicies.md` DocC
article. Landing the move in a single PR alongside the re-export
shim is the safer path; this PR documents the intent so reviewers
of a future trust-split PR have a contemporaneous design rationale.

## 4.x Reference Signers — AWS SigV4 and JWT Bearer

`HMACRequestInterceptor` is the only request signer shipped in 4.0. The
4.x roadmap adds two more reference implementations so the most common
external-API conventions are covered without every adopter writing
their own:

- **AWS SigV4** — canonical-request signer for AWS APIs and any service
  that adopts the same authorization scheme. Ships as
  `AWSSigV4Interceptor` in a follow-up minor; the wire shape is
  documented today in [`RequestSigning.md`](../Sources/InnoNetwork/InnoNetwork.docc/Articles/RequestSigning.md).
- **JWT Bearer (request-minted)** — interceptor shape for backends that
  expect a JWT computed per request (claims include method/path).
  `RefreshTokenPolicy` already covers session-rotated bearer tokens, so
  this signer targets the request-minted lane only.

Both signers will keep key material outside the interceptor (closure
injection so adopters can use Keychain or Secure Enclave); both ride
on the existing `RequestInterceptor` contract. Streaming-body variants
(SigV4 chunk-signed) are explicitly deferred — the interceptor surface
runs before the upload pipeline owns the body, so chunk signing needs
a deeper hook that is not yet planned.

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
