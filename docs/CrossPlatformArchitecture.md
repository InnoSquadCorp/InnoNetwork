# Cross-platform architecture

## Decision

InnoNetwork uses one repository and product identity, but every runtime keeps
its native transport:

```text
optional endpoint authoring / compile-time generation
                         │
             typed definition + client
                         │
              native low-level session
          ┌──────────────┼──────────────┐
 Apple: URLSession   Android: OkHttp   Web: Fetch
```

Android accepts `okhttp3.Request`; Web accepts Fetch inputs and `RequestInit`.
The library does not replace platform request builders, TLS stacks, caches,
interceptors, cookies, CORS, CSP, or observability integrations.

## Swift-main alignment and scope

The root SwiftPM distribution follows the current `main` branch and the latest
public stable release is 6.1.1. It contains nine runtime products plus the
compiler-host-only `InnoNetworkMacroSupport` product. Android/Web 1.0 align the
core native-session behaviors, not every Swift product or every 6.x pipeline
feature.

| Contract | Apple root | Android 1.0 | Web 1.0 |
| --- | --- | --- | --- |
| Native request | `URLRequest` | OkHttp `Request` | Fetch `Request` / `RequestInit` |
| Typed endpoint | Swift `APIDefinition` / macros | `APIDefinition` / optional KSP | `APIDefinition` + TypeScript `satisfies` |
| Buffered call | URLSession data task | `NetworkSession.data` | `NetworkSession.data` |
| Cancellation | Swift task cancellation | coroutine to `Call.cancel()` | `AbortSignal` |
| HTTP 4xx/5xx | response value | response value | response value |
| Typed decode | Codable/custom codecs | explicit serializer/decoder | runtime decoder from `unknown` |
| Large body | bytes/download products | caller-owned `open()` | native response from `open()` |

Authentication/refresh, retry, circuit breaker, coalescing, operation handles,
cache, upload/download, WebSocket, OpenAPI, trust, AWS, and test support remain
root Swift features until separately designed and verified for another runtime.

## Retrofit replacement boundary

The Android package replaces Retrofit's endpoint execution/conversion layer,
not OkHttp:

- `OkHttpNetworkSession.data(request)` bridges calls to structured coroutine
  cancellation and returns immutable bounded data;
- `open(request)` returns a caller-owned streaming response;
- `innonetwork-client` supplies the optional typed client;
- `innonetwork-ksp` generates native request construction only;
- `innonetwork-kotlinx-serialization` performs explicit serializer-based JSON;
- native interceptors, authenticators, TLS, cache, connection pooling, and
  `EventListener` remain visible.

## Macro-first, transport-first

Compile-time authoring is useful only after the native transport contract is
stable. The order is:

1. establish native request, cancellation, status, error, and resource limits;
2. validate real manual consumers;
3. add optional compile-time endpoint authoring;
4. keep generated output inspectable and able to call the same low-level API.

The mechanism is platform-specific: Swift macros, Kotlin KSP, and TypeScript
structural typing. Generated code must not hide the native escape hatch.

## Release boundary

The existing SwiftPM entry point stays at the repository root; Android and Web
stay under `Platforms/Android` and `Platforms/Web`. No Swift source/manifest or
consumer URL migration is introduced. See [layout and releasing](../Platforms/RELEASING.md)
for canonical paths, executable layout checks and independent publication gates.

Android and Web begin independent 1.x SemVer lines. Local gates validate Maven
artifacts, npm tarballs, consumers, API/ABI baselines, failure diagnostics,
React StrictMode/replacement, R8 packaging, and native browser behavior. See
[`Platforms/RELEASE_READINESS.md`](../Platforms/RELEASE_READINESS.md) for actual
local execution and remaining qualifications. Remote CI/CodeQL, registry
credentials, signing/provenance, tags, and publication remain separate release
evidence; checked-in `1.0.0` source is a release candidate until they complete.
