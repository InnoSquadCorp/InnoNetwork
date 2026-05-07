# Migrating to InnoNetwork 5.0

The 5.0 release tightens the public surface and broadens platform
reach without rewriting the request pipeline. Most adopters move
through the upgrade with a recompile and a one-pass `sed` over
import sites.

This guide is published during the 4.x line so adopters can prepare
incrementally. The 5.0-prep changes that already shipped in 4.x are
marked **(in 4.x)**; the rest land at the 5.0 cut.

## Headline changes

| Area | 4.x baseline | 5.0 |
| --- | --- | --- |
| Platform floors **(in 4.x)** | iOS 18 / macOS 15 / tvOS 18 / watchOS 11 / visionOS 2 | iOS 16 / macOS 14 / tvOS 16 / watchOS 9 / visionOS 1 |
| Endpoint vocabulary **(alias in 4.x, primary in 5.0)** | `EndpointShape`, `EndpointAuthScope`, `ScopedEndpoint` | `Endpoint`, `AuthScope`, `EndpointBuilder` |
| `NetworkConfiguration` shape | flat init with N parameters | optional packs (`ResiliencePack`, `AuthPack`, `ObservabilityPack`, `CachePack`, `TransportPack`) |
| `NetworkError` ledger | nine cases including `invalidBaseURL` and `invalidRequestConfiguration` | consolidated `configuration(reason:)` plus `@unknown default` migration guidance |
| Required imports | `import InnoNetwork` | unchanged |

Every other public symbol stays source-compatible.

## Already in 4.x — no action required

The following items shipped during the 4.x line so 5.0 adoption is
incremental rather than a cliff:

- Forward-compatibility typealiases for the rename. `Endpoint`,
  `AuthScope`, and `EndpointBuilder<Response, AuthScope>` are
  available today and resolve to the legacy names. New call sites
  may adopt the new vocabulary now; existing call sites keep
  compiling unchanged.
- Platform floor backport. The 4.x → 4.x point releases lowered the
  minimum SDKs to iOS 16 / macOS 14 / tvOS 16 / watchOS 9 /
  visionOS 1. Adopters on those SDKs can pick up the 4.x line
  without an OS bump.
- Privacy manifest, `urlSessionConfigurationOverride` for cookie
  isolation and HTTP/3, the Stable Examples contract, and the
  `HMACRequestInterceptor` reference all land in 4.x and stay
  source-compatible into 5.0.

If your codebase already builds against the latest 4.x, the
remaining 5.0 work is bounded to the items below.

## What changes at the 5.0 cut

### Endpoint vocabulary becomes primary

The 5.0 release demotes the legacy names to
`@available(*, deprecated, renamed:)` aliases. Any call site that
still references `EndpointShape`, `EndpointAuthScope`, or
`ScopedEndpoint` keeps compiling but emits a deprecation warning.

Recommended migration:

```swift
// 4.x — both forms compile, no warnings
struct GetUser: APIDefinition { /* ... */ }
let endpoint = ScopedEndpoint<User, PublicAuthScope>.get("/users/1")
    .decoding(User.self)

// 5.0 — primary form, no warning
let endpoint = EndpointBuilder<User, PublicAuthScope>.get("/users/1")
    .decoding(User.self)
```

`APIDefinition` keeps its name in both releases — only the marker
protocol (`EndpointShape` → `Endpoint`) and the builder
(`ScopedEndpoint` → `EndpointBuilder`) move.

A `Scripts/migrate-5.0.sh` companion script will ship with the 5.0
release to apply the rename across consumer codebases via `sed`.

### `NetworkConfiguration` packs become optional

The 5.0 builder grows pack-shaped optional parameters that compose
the existing knobs into thematic groups, without removing the flat
parameter list:

```swift
let config = NetworkConfiguration.advanced(baseURL: baseURL) { builder in
    // 4.x — still works in 5.0
    builder.retryPolicy = ExponentialBackoffRetryPolicy(...)
    builder.refreshTokenPolicy = ...
    builder.requestInterceptors.append(...)

    // 5.0 — pack-shaped alternative
    builder.resilience = ResiliencePack(
        retry: ExponentialBackoffRetryPolicy(...),
        circuitBreaker: ...
    )
    builder.auth = AuthPack(refreshToken: ..., signature: HMACRequestInterceptor(...))
}
```

Adopters who use `safeDefaults(baseURL:)` or
`recommendedForProduction(baseURL:)` see no surface change; only
direct `AdvancedBuilder` users benefit from (or need to migrate to)
the packs.

### `NetworkError` ledger consolidation

Two case shapes that overlap with each other (`invalidBaseURL(_:)`
and `invalidRequestConfiguration(_:)`) are merged into a single
`configuration(reason:)` with a typed reason payload. The legacy
cases stay as `@available(*, deprecated, renamed:)` shadows so
existing `switch` statements keep compiling, but the deprecation
warning surfaces the recommended new shape.

```swift
// 4.x
catch let error as NetworkError {
    switch error {
    case .invalidBaseURL(let message):           handle(message)
    case .invalidRequestConfiguration(let msg):  handle(msg)
    // ...
    }
}

// 5.0
catch let error as NetworkError {
    switch error {
    case .configuration(let reason):
        switch reason {
        case .invalidBaseURL(let message): handle(message)
        case .invalidRequest(let message): handle(message)
        }
    // ...
    @unknown default: assertionFailure("Unhandled NetworkError case")
    }
}
```

`NetworkError` does **not** become `@frozen` in 5.0 — adding new
cases for new failure modes (e.g. circuit-breaker tripping)
remains a non-breaking minor change. The `@unknown default`
guidance in the case-handling docs stays in place for the same
reason.

### Platform floors

The platform-floor change already shipped during the 4.x line, so
5.0 simply removes the now-redundant 4.x → 5.0 wording in
docs/PlatformSupport.md. No code-level change is required.

## Compatibility timeline

| Release | Action |
| --- | --- |
| 4.x point releases | Ship typealias forwards, platform backport, all non-breaking 5.0 prep. |
| 4.x final | Add `@available(*, deprecated, renamed:)` markers to legacy names so deprecation warnings surface in adopters' builds. |
| 5.0.0 | Promote new names to primary, ship `Scripts/migrate-5.0.sh`, document migration. |
| 5.x | Continue resolving deprecated names; no removal. |
| 6.0 | Remove the deprecated aliases. |

This compatibility window matches Apple's own SDK rename cadence
and gives adopters at least 12 months between deprecation warning
and removal.

## Pre-flight checklist

Before adopting 5.0:

- [ ] Move call sites to the new typealiases (`Endpoint`,
  `AuthScope`, `EndpointBuilder`) while still on 4.x. The aliases
  ship without deprecation warnings, so the migration is safe to
  do at any pace.
- [ ] Audit `URLSessionConfiguration` overrides if you use the
  cookie isolation or HTTP/3 patterns from `docs/Cookies.md` and
  `docs/HTTP3.md` — both compose with 5.0 transport packs without
  rewrites.
- [ ] If you depend on `NetworkError` with exhaustive switches,
  wrap them in `@unknown default` *now* so the 5.0 case
  consolidation surfaces as a compile-time hint rather than an
  unhandled case.
- [ ] If you ship to iOS 16 / macOS 14 yet, the platform floor
  backport in 4.x already unblocks you — the 5.0 release does not
  change those numbers.

## See also

- [API_STABILITY.md](../API_STABILITY.md) for the symbol-level
  contract distinguishing Stable from Provisionally Stable APIs.
- [Migration-4.0.0.md](Migration-4.0.0.md) for the previous major
  upgrade.
- [MIGRATION_POLICY.md](MIGRATION_POLICY.md) for the project's
  general migration philosophy.
