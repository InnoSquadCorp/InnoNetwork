# Client Architecture

InnoNetwork's public request API remains `DefaultNetworkClient.request(_:)`.
The released 5.x contract preserves the resilience stages while making request
identity and late, body-aware signing explicit around the raw transport
attempt.

Named application endpoints should remain explicit value types. The root
`@APIDefinition(method:path:auth:)` macro derives their repetitive conformance
witnesses, but the struct still owns stored inputs, `APIResponse`, and any
custom transport or policy. `EndpointBuilder` remains the stable escape for a
one-off or runtime-composed request.

## Request Path

```text
session-authentication preflight
  -> build request and body
  -> configuration request interceptors
  -> endpoint request interceptors
  -> apply current refresh token
  -> unsigned-only cache lookup / conditional headers
  -> snapshot file body and apply request signers
  -> custom execution policies
  -> circuit breaker
  -> unsigned-only request coalescing
  -> transport
  -> unsigned-only cache write / 304 substitution
  -> response interceptors
  -> status validation
  -> decode
```

Built-in policies occupy the preflight and post-transport slots:

- `RefreshTokenPolicy` applies the current token, refreshes on configured auth
  status codes, and replays the fully adapted request once.
- `RequestSigner` observes the finalized data or stable file body after
  interceptors and token application. Signed requests disable response-cache
  sharing, coalescing, URLSession caching, and automatic redirects.
- `RequestCoalescingPolicy` shares one raw `(Data, HTTPURLResponse)` result
  among identical unsigned in-flight requests.
- `ResponseCachePolicy` can return cached unsigned GET responses, revalidate
  with ETag, substitute `304` bodies, refresh stale entries in the background,
  and invalidate cached target URIs after successful unsafe methods.
- `CircuitBreakerPolicy` short-circuits repeated per-host failures before
  transport and surfaces open-circuit failures through `NetworkError.underlying`.
- `RequestExecutionPolicy` observes or wraps one raw transport attempt when
  applications need custom tracing, admission control, or response rewriting
  below interceptors but above `URLSession`.

## Public Surface Policy

The 5.x contract exposes ``RequestExecutionPolicy`` as a request-identity-preserving
extension point, while keeping the built-in retry, refresh, coalescing, cache,
and circuit-breaker policies as first-class configuration values on
`NetworkConfiguration`.

Custom policies should be small and transport-attempt scoped. They receive the
adapted `URLRequest` as an immutable observation snapshot and may invoke
``RequestExecutionNext`` zero, one, or multiple times. Every `execute()` call
forwards the same executor-owned request: URL, header, and body mutation belongs
in a ``RequestInterceptor``. For example, a replay policy may invoke `next`
repeatedly, while a synthetic-response policy may return without invoking
`next` at all. The policy must always return a full ``Response``. Custom
policies should not try to replace retry scheduling, auth refresh replay,
response-cache freshness, or circuit-breaker state; those remain owned by the
built-in policy layers so cancellation, metrics, and cache semantics stay
consistent.

## Session Authentication

Every `APIDefinition` declares how it participates in the configured bearer
token refresh policy:

```swift
var sessionAuthentication: SessionAuthentication { get }
```

Fluent calls use `EndpointBuilder<Response>` and choose
`.authentication(.anonymous)`, `.authentication(.optional)`, or
`.authentication(.required)`. A custom `APIDefinition` exposes the same choice
through its `sessionAuthentication` property. Required requests fail before transport with
`NetworkError.configuration(reason: .invalidRequest(...))` when the client
configuration has no `RefreshTokenPolicy`; token acquisition failures also
surface without sending an anonymous request. Anonymous endpoints never invoke
the policy, while optional endpoints may use it when configured but can proceed
without one.

## Macro Boundary

The root package's default `Macros` trait exposes `@APIDefinition` through
`import InnoNetwork`. It derives method, percent-encoded path,
`sessionAuthentication`, and simple body/query payload witnesses. Stored
`query` values are inferred for GET/HEAD; stored `body` values are inferred for
POST/PUT/PATCH/DELETE. Missing response/auth contracts and ambiguous
definitions fail at compile time. It does not generate client
methods or absorb headers, interceptors, transport, decoding, multipart, or
streaming responsibilities.

Core-only consumers can request `traits: []` consistently across their
dependency graph. This excludes the macro API and compiler plug-in compilation,
although SwiftPM can still resolve or fetch package-level `swift-syntax` while
evaluating manifests. Package traits are unified across the resolved graph, so
another dependency that enables default traits can re-enable `Macros`.
Macro usage is documented in
[`UsingMacros.md`](../Sources/InnoNetwork/InnoNetwork.docc/Articles/UsingMacros.md).
