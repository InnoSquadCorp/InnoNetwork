# Client Architecture

InnoNetwork's public request API remains `DefaultNetworkClient.request(_:)`.
4.0.0 adds built-in resilience features by splitting the internal executor into
explicit stages while keeping the generic execution pipeline package-scoped.

## Request Path

```text
build request
  -> configuration request interceptors
  -> endpoint request interceptors
  -> built-in preflight policies
  -> transport
  -> built-in post-transport policies
  -> response interceptors
  -> status validation
  -> decode
```

Built-in policies occupy the preflight and post-transport slots:

- `RefreshTokenPolicy` applies the current token, refreshes on configured auth
  status codes, and replays the original request once.
- `RequestCoalescingPolicy` shares one raw `(Data, HTTPURLResponse)` result
  among identical in-flight requests.
- `ResponseCachePolicy` can return cached GET responses, revalidate with ETag,
  substitute `304` bodies, and refresh stale entries in the background.
- `CircuitBreakerPolicy` short-circuits repeated per-host failures before
  transport and surfaces open-circuit failures through `NetworkError.underlying`.

## Public Surface Policy

4.0.0 intentionally does not expose a public `RequestExecutionPolicy` protocol.
The supported public contract is the set of built-in policy configuration
values on `NetworkConfiguration` and `NetworkConfiguration.AdvancedBuilder`.

This keeps the pipeline free to evolve while still covering the common
production features that need privileged executor access: replay, raw transport
fan-out, cache substitution, and failure classification.

## Optional Codegen

`InnoNetworkCodegen` is a separate product. Consumers that import only
`InnoNetwork` do not link `swift-syntax` into the runtime product. SwiftPM
still declares `swift-syntax` at the package graph level for the macro target
and may resolve or fetch it depending on the selected products and tooling.
True resolution isolation is a post-4.0 package-splitting candidate. Macro
usage is documented in
[`UsingMacros.md`](../Sources/InnoNetwork/InnoNetwork.docc/Articles/UsingMacros.md).
