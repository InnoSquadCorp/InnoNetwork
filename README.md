# InnoNetwork

[![CI](https://github.com/InnoSquadCorp/InnoNetwork/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/InnoSquadCorp/InnoNetwork/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/InnoSquadCorp/InnoNetwork/branch/main/graph/badge.svg)](https://codecov.io/gh/InnoSquadCorp/InnoNetwork)
[![DocC](https://img.shields.io/badge/docs-DocC-blue)](https://innosquadcorp.github.io/InnoNetwork/)
[![Swift](https://img.shields.io/badge/Swift-6.2-orange)](https://swift.org)
[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)](https://swift.org/package-manager)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2018%20%7C%20macOS%2015%20%7C%20tvOS%2018%20%7C%20watchOS%2011%20%7C%20visionOS%202-lightgrey)](#platform-matrix)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

InnoNetwork is a Swift package for type-safe networking on Apple platforms. It provides four public products:

- `InnoNetwork` for request/response APIs
- `InnoNetworkDownload` for download lifecycle management
- `InnoNetworkWebSocket` for connection-oriented realtime flows
- `InnoNetworkCodegen` for optional Swift macro endpoint helpers

The package is built around Swift Concurrency, explicit transport policies, and operational visibility that can scale from app prototypes to production clients.

> ⚠️ **Apple platforms only by design.** InnoNetwork builds on URLSession, `OSAllocatedUnfairLock`, OSLog, and Network.framework, none of which match Apple-platform behaviour on Linux. Linux/server-side Swift is **not** a supported target. See [docs/PlatformSupport.md](docs/PlatformSupport.md) for the rationale and for guidance on sharing models with Linux server code (e.g. Vapor).

> 📚 **API Reference (DocC):** https://innosquadcorp.github.io/InnoNetwork/
> 🇰🇷 **한국어 문서:** [docs/ko/README.md](docs/ko/README.md)

## Quick Start

### Install

```swift
dependencies: [
    .package(url: "https://github.com/InnoSquadCorp/InnoNetwork.git", branch: "release/v4.0")
]
```

`4.0.0` is the upcoming 4.x public release baseline. Until the tag exists, pin
the `release/v4.0` branch or a specific repository revision when validating
these unreleased changes.

### Core Request

```swift
import Foundation
import InnoNetwork

struct GetUser: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = User

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
}

struct User: Decodable, Sendable {
    let id: Int
    let name: String
}

let client = DefaultNetworkClient(
    configuration: .safeDefaults(
        baseURL: URL(string: "https://api.example.com/v1")!
    )
)

let user = try await client.request(GetUser())
print(user)
```

For simple endpoints that only need method, path, query/body parameters,
headers, content type, and response decoding, use the builder-style
`Endpoint` API. Keep a dedicated `APIDefinition` type when an endpoint owns
interceptors, custom encoders/decoders, multipart uploads, or streaming.

```swift
let user = try await client.request(
    Endpoint.get("/users/1").decoding(User.self)
)

let users = try await client.request(
    Endpoint.get("/users")
        .query(["limit": 20])
        .decoding([User].self)
)
```

### Download

```swift
import Foundation
import InnoNetworkDownload

let manager = DownloadManager.shared
let task = await manager.download(
    url: URL(string: "https://example.com/file.zip")!,
    toDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
)

for await event in await manager.events(for: task) {
    print(event)
}
```

#### Destination filename policy

`download(url:toDirectory:fileName:)` resolves the destination as:

- If `fileName:` is provided, it is used verbatim under `directory`.
- Otherwise the URL's last path component (`url.lastPathComponent`) is used.
- The library does **not** rename on collision — if a file already exists at the resolved
  path, the download will overwrite it once it completes. Pass an explicit `fileName:` (for
  example, prefixed with the task UUID) when concurrent or repeated downloads to the same
  directory must coexist.

For absolute control over the destination path, use `download(url:to:)` instead and
construct the target URL yourself.

### WebSocket

```swift
import Foundation
import InnoNetworkWebSocket

let task = await WebSocketManager.shared.connect(
    url: URL(string: "wss://echo.example.com/socket")!
)

for await event in await WebSocketManager.shared.events(for: task) {
    print(event)
}
```

## Products

### `InnoNetwork`

- async/await request execution
- type-safe `APIDefinition` modeling
- JSON, form-url-encoded, and multipart request support
- retry coordination, auth refresh, request coalescing, response cache, and circuit breaker policies
- trust policy support and request lifecycle observability

### `InnoNetworkDownload`

- foreground and background download orchestration
- pause, resume, retry, and listener retention across retries
- append-log persistence for durable task restoration
- `AsyncStream` and listener-based event delivery

### `InnoNetworkWebSocket`

- heartbeat and pong timeout handling
- reconnect policies with handshake-aware close taxonomy
- listener retention across reconnect attempts
- `AsyncStream` and listener-based event delivery

### `InnoNetworkCodegen`

- optional `@APIDefinition` and `#endpoint` macros
- links `swift-syntax` only through the codegen/macro targets
- keeps the core `InnoNetwork` runtime target free of external library
  dependencies, while SwiftPM may still resolve package-level macro
  dependencies during package graph loading

## Platform Matrix

- iOS 18.0+
- macOS 15.0+
- tvOS 18.0+
- watchOS 11.0+
- visionOS 2.0+
- Swift 6.2+

The package intentionally targets current Apple platform releases. That lets the codebase rely on modern Swift Concurrency semantics, stricter Sendable checking, and the latest URLSession and platform APIs without compatibility shims.

## Protocol Buffers

Protocol Buffers support moved to the separate `InnoNetworkProtobuf` package. Consumers that need protobuf request and response modeling must add `InnoNetworkProtobuf` alongside `InnoNetwork` in the same package manifest.

```swift
dependencies: [
    .package(url: "https://github.com/InnoSquadCorp/InnoNetwork.git", branch: "release/v4.0"),
    .package(url: "https://github.com/InnoSquadCorp/InnoNetworkProtobuf.git", branch: "main")
]
```

`InnoNetworkProtobuf` is being prepared for its first tagged release. Until
that tag exists, follow the `main` branch of `InnoNetworkProtobuf` together
with the unreleased InnoNetwork 4.0 release branch or a pinned revision.

## Configuration

The recommended entry point is `safeDefaults`. Use `advanced` only when you need explicit operational tuning.

```swift
import Foundation
import InnoNetwork
import InnoNetworkDownload
import InnoNetworkWebSocket

let network = NetworkConfiguration.safeDefaults(
    baseURL: URL(string: "https://api.example.com")!
)

let download = DownloadConfiguration.safeDefaults(
    sessionIdentifier: "com.example.app.downloads"
)

let socket = WebSocketConfiguration.safeDefaults()

let tunedNetwork = NetworkConfiguration.advanced(
    baseURL: URL(string: "https://api.example.com")!
) { builder in
    builder.timeout = 30
    builder.retryPolicy = ExponentialBackoffRetryPolicy()
    builder.trustPolicy = .systemDefault
    builder.requestCoalescingPolicy = .getOnly
    builder.responseCache = InMemoryResponseCache()
    builder.responseCachePolicy = .cacheFirst(maxAge: .seconds(60))
}
```

Auth refresh, coalescing, caching, and circuit breaking are opt-in. The
request execution pipeline stays internal; public configuration exposes only
the built-in policies.

```swift
let refreshPolicy = RefreshTokenPolicy(
    currentToken: { try await tokenStore.currentAccessToken() },
    refreshToken: { try await authService.refreshAccessToken() }
)

let client = DefaultNetworkClient(
    configuration: .advanced(
        baseURL: URL(string: "https://api.example.com")!
    ) { builder in
        builder.refreshTokenPolicy = refreshPolicy
        builder.circuitBreakerPolicy = CircuitBreakerPolicy(failureThreshold: 3)
    }
)
```

### Optional Macros

Add `InnoNetworkCodegen` only when you want compile-time endpoint helpers:

```swift
import InnoNetwork
import InnoNetworkCodegen

@APIDefinition(method: .get, path: "/users/{id}")
struct GetUser {
    typealias APIResponse = User
    let id: Int
}

let endpoint = #endpoint(.get, "/users/1", as: User.self)
```

See [Using Macros](Sources/InnoNetwork/InnoNetwork.docc/Articles/UsingMacros.md)
for the supported scope.

## Error Handling

InnoNetwork favors explicit transport errors over opaque failures.

```swift
do {
    let user = try await client.request(GetUser())
    print(user)
} catch let error as NetworkError {
    switch error {
    case .invalidBaseURL(let url):
        print("Invalid base URL: \(url)")
    case .invalidRequestConfiguration(let message):
        print("Invalid request configuration: \(message)")
    case .statusCode(let response):
        print("Unexpected status code: \(response.statusCode)")
    case .objectMapping(let underlying, _):
        print("Decoding failed: \(underlying)")
    case .trustEvaluationFailed(let reason):
        print("Trust evaluation failed: \(reason)")
    case .cancelled:
        print("Request cancelled")
    default:
        print(error)
    }
}
```

`invalidRequestConfiguration` usually means request shape and policy do not match. Common examples are:

- sending a top-level scalar or array query without `queryRootKey`
- mismatching `contentType` and request payload semantics
- using a malformed multipart payload

For operational tuning, see [Examples](Examples/README.md) and [API Stability](API_STABILITY.md).

## Stability

Public releases follow semantic versioning. `4.0.0` is the upcoming public
baseline for the 4.x major line; until it is tagged, use `release/v4.0` or a
specific revision for validation.

- Stable public API: [API_STABILITY.md](API_STABILITY.md)
- Release rules and compatibility policy: [docs/RELEASE_POLICY.md](docs/RELEASE_POLICY.md)
- Migration expectations: [docs/MIGRATION_POLICY.md](docs/MIGRATION_POLICY.md)

`safeDefaults` is the recommended public path. `default` aliases remain available for compatibility, but new examples and new integrations should prefer `safeDefaults`.

`request` and `upload` are the recommended request execution APIs for 4.0.0
integrations. Lower-level extension points that exist in the source tree are
not part of the 4.0.0 stable public contract.

For long-lived line-delimited transports (Server-Sent Events, NDJSON, log
streams), use `DefaultNetworkClient.stream(_:)` together with a
`StreamingAPIDefinition`. To cancel every in-flight request and stream
(for example, on logout or backgrounding), call
`DefaultNetworkClient.cancelAll()`. See
[docs/releases/4.0.0.md](docs/releases/4.0.0.md) for full release details.

## Benchmarks

The repository includes a dedicated benchmark runner for quick local comparisons.

```bash
swift run InnoNetworkBenchmarks --quick
swift run InnoNetworkBenchmarks --json-path /tmp/innonetwork-bench.json
```

Benchmark governance, baseline policy, and CI posture are documented in [Benchmarks/README.md](Benchmarks/README.md).

## Production Checklist

Operational items to verify before shipping a client built on InnoNetwork.

### Trust & Transport Security

- **TLS pinning rotation.** When using `TrustPolicy.publicKeyPinning(...)`, ship at least two
  pins (current + next) and document the rotation cadence so the app keeps validating after
  certificate replacement. Consider feature-gated rollback to `.systemDefault` for emergency
  recovery.
- **Pinning host matching.** Keep the default `.unionAllMatches` if parent-domain pins should
  act as backup pins for subdomains. Use `.mostSpecificHost` when `example.com` and
  `api.example.com` pins must be operated as separate trust scopes.
- **App Transport Security (ATS).** The default `safeDefaults` configuration assumes ATS is
  enabled. Avoid `NSAllowsArbitraryLoads` in production `Info.plist`. If a non-HTTPS host is
  unavoidable, scope an `NSExceptionDomains` entry to that host only.
- **Custom trust evaluation.** A `TrustEvaluating` implementation runs before request bodies are
  ever decoded, so a rejected challenge becomes `NetworkError.trustEvaluationFailed`. Surface
  the failure to a user-facing recovery path; do not auto-retry on trust failure.

### Background Operation

- **Background download Info.plist.** Background sessions require declaring
  `UIBackgroundModes` with `fetch` (and `processing` if you use long-running tasks).
- **Session identifier uniqueness.** Each `DownloadConfiguration.sessionIdentifier` must be
  globally unique within the app process. Reuse causes Foundation to merge tasks; the library
  asserts in DEBUG and emits an OSLog `.fault` in RELEASE.
- **Background completion handler.** Wire the system-provided completion handler (delivered to
  `application(_:handleEventsForBackgroundURLSession:completionHandler:)`) into
  `DownloadManager` so the OS releases the app suspension promptly.

### Observability & Privacy

- **Redaction defaults.** `NetworkLogger` and `OSLogNetworkEventObserver` mark URLs, headers,
  and request bodies as `.private` by default. Do not flip them to `.public` outside of
  controlled diagnostic builds.
- **Failure payload capture.** `NetworkError.objectMapping(_, response)` carries a `Response`;
  by default that `response.data` is redacted to empty data unless you opt in via
  `NetworkConfiguration.captureFailurePayload = true`. Keep that flag off in release
  configurations to avoid storing PII inside crash logs or analytics.
- **Event observer attachment.** Attach observers (`NetworkEventObserving`) at app start and
  detach on logout / account switch. Observers receive every request event, including ones
  triggered after a user-initiated cancellation.

### Resilience

- **Cancel-on-logout.** Call `DefaultNetworkClient.cancelAll()` when the user logs out,
  switches accounts, or backgrounds. Streaming requests (SSE/NDJSON) only stop when their
  parent task is cancelled.
- **Retry budget.** `ExponentialBackoffRetryPolicy.maxTotalRetries` is the absolute cap that
  network-monitor recovery does not reset. Budget per user session, not per request.
- **Auth refresh.** Prefer `RefreshTokenPolicy` over response interceptors for
  `401` refresh + replay. The policy single-flights concurrent refreshes and
  replays each fully adapted request at most once.
- **Cache and circuit breaker.** Enable `ResponseCachePolicy` and
  `CircuitBreakerPolicy` per client only after deciding the cache freshness and
  host-failure budget for that API. Cache keys include `Authorization` and
  `Accept-Language`; full HTTP `Vary` processing is not automatic in 4.0.
- **WebSocket reconnect cap.** `maxReconnectAttempts` limits successive automatic attempts.
  After exhaustion, surface the failure to the UI rather than reconnect on every app
  foreground.

### Push & Lifecycle Refresh

- **Background fetch friendly.** Streaming or websocket products expect explicit
  `disconnect()` calls before app suspension. Implement `applicationDidEnterBackground`
  cleanup; the OS will not gracefully close sockets on your behalf.
- **Token refresh.** Keep token application, signing, and tenant headers in
  `RequestInterceptor`s, and configure `RefreshTokenPolicy` for `401` refresh
  + replay. The policy owns the single-flight refresh so concurrent retries do
  not stampede the refresh endpoint.

### Pre-flight Test Plan

| Area | Smoke check |
|------|-------------|
| Trust | Hit a host pinned to a wrong certificate and verify `NetworkError.trustEvaluationFailed`. |
| Retry | Stub a `503 Retry-After: 30` response and confirm the policy honours the header. |
| Background download | Kill the app mid-download, relaunch, and verify `DownloadRestoreCoordinator` resumes. |
| WebSocket reconnect | Drop the network for >10s, restore, and verify only the configured number of attempts ran. |
| Cancel-all | Trigger `cancelAll()` while a stream and an upload are in flight; both must terminate with `.cancelled`. |

## Documentation

- DocC API Reference: https://innosquadcorp.github.io/InnoNetwork/
- Examples: [Examples/README.md](Examples/README.md)
- API Stability: [API_STABILITY.md](API_STABILITY.md)
- Client Architecture: [docs/ClientArchitecture.md](docs/ClientArchitecture.md)
- Platform Support: [docs/PlatformSupport.md](docs/PlatformSupport.md)
- Release Policy: [docs/RELEASE_POLICY.md](docs/RELEASE_POLICY.md)
- Migration Policy: [docs/MIGRATION_POLICY.md](docs/MIGRATION_POLICY.md)
- DocC Deployment: [docs/DocC_Deployment.md](docs/DocC_Deployment.md)
- Query Encoding Reference: [docs/QueryEncoding.md](docs/QueryEncoding.md)
- WebSocket Lifecycle: [docs/WebSocketLifecycle.md](docs/WebSocketLifecycle.md)
- Release Notes: [docs/releases/4.0.0.md](docs/releases/4.0.0.md)
- Roadmap: [docs/ROADMAP.md](docs/ROADMAP.md)
- 한국어 문서: [docs/ko/README.md](docs/ko/README.md)

## Support

InnoNetwork follows a lightweight maintainer model.

- Support policy: [SUPPORT.md](SUPPORT.md)
- Contributing guide: [CONTRIBUTING.md](CONTRIBUTING.md)
- Security reporting: [SECURITY.md](SECURITY.md)
- Changelog: [CHANGELOG.md](CHANGELOG.md)
- Code of Conduct: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)

## License

MIT. See [LICENSE](LICENSE).
