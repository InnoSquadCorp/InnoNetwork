# Client Architecture

InnoNetwork's public request API remains `DefaultNetworkClient.request(_:)`.
4.0.0 adds built-in resilience features by splitting the internal executor into
explicit stages and exposing a narrow custom execution-policy hook around the
raw transport attempt.

## Request Path

```text
build request
  -> configuration request interceptors
  -> endpoint request interceptors
  -> auth-scope preflight
  -> built-in preflight policies
  -> custom execution policies
  -> transport
  -> built-in post-transport policies
  -> response interceptors
  -> status validation
  -> decode
```

Built-in policies occupy the preflight and post-transport slots:

- `RefreshTokenPolicy` applies the current token, refreshes on configured auth
  status codes, and replays the fully adapted request once.
- `RequestCoalescingPolicy` shares one raw `(Data, HTTPURLResponse)` result
  among identical in-flight requests.
- `ResponseCachePolicy` can return cached GET responses, revalidate with ETag,
  substitute `304` bodies, and refresh stale entries in the background.
- `CircuitBreakerPolicy` short-circuits repeated per-host failures before
  transport and surfaces open-circuit failures through `NetworkError.underlying`.
- `RequestExecutionPolicy` wraps one raw transport attempt when applications
  need custom tracing, request signing, A/B routing, or response rewriting that
  belongs below interceptors but above `URLSession`.

## Public Surface Policy

4.0.0 exposes ``RequestExecutionPolicy`` as an additive extension point, while
keeping the built-in retry, refresh, coalescing, cache, and circuit-breaker
policies as first-class configuration values on `NetworkConfiguration`.

Custom policies should be small and transport-attempt scoped. They receive the
adapted `URLRequest` and may invoke ``RequestExecutionNext`` zero, one, or
multiple times — for example, a retry policy that replays the chain after a
transient failure invokes `next` repeatedly, while a synthetic-response policy
may decide to return without invoking `next` at all. The policy must always
return a full ``Response``. Custom policies should not try to replace retry
scheduling, auth refresh replay, response-cache freshness, or circuit-breaker
state; those remain owned by the built-in policy layers so cancellation,
metrics, and cache semantics stay consistent.

## Auth Scope

`APIDefinition` now carries an auth marker:

```swift
associatedtype Auth: EndpointAuthScope = PublicAuthScope
```

Fluent public endpoints use `ScopedEndpoint<Response, PublicAuthScope>`.
Authenticated fluent calls use `ScopedEndpoint<Response, AuthRequiredScope>`,
or a custom `APIDefinition` with `typealias Auth = AuthRequiredScope`.
Auth-required requests fail before transport with
`NetworkError.invalidRequestConfiguration` when the client configuration has no
`RefreshTokenPolicy`.

## Optional Codegen

`InnoNetworkCodegen` is a separate package under
`Packages/InnoNetworkCodegen`. Consumers that depend only on the root
`InnoNetwork` package do not resolve, fetch, or build `swift-syntax`; macro
users opt into that package explicitly. Macro usage is documented in
[`UsingMacros.md`](../Sources/InnoNetwork/InnoNetwork.docc/Articles/UsingMacros.md).
