# InnoNetwork

[![CI](https://github.com/InnoSquadCorp/InnoNetwork/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/InnoSquadCorp/InnoNetwork/actions/workflows/ci.yml)
[![TSAN Nightly](https://github.com/InnoSquadCorp/InnoNetwork/actions/workflows/tsan.yml/badge.svg?branch=main)](https://github.com/InnoSquadCorp/InnoNetwork/actions/workflows/tsan.yml)
[![Nightly Live Smoke](https://github.com/InnoSquadCorp/InnoNetwork/actions/workflows/nightly-live.yml/badge.svg?branch=main)](https://github.com/InnoSquadCorp/InnoNetwork/actions/workflows/nightly-live.yml)
[![codecov](https://codecov.io/gh/InnoSquadCorp/InnoNetwork/branch/main/graph/badge.svg)](https://codecov.io/gh/InnoSquadCorp/InnoNetwork)
[![DocC](https://img.shields.io/badge/docs-DocC-blue)](https://innosquadcorp.github.io/InnoNetwork/)
[![Swift](https://img.shields.io/badge/Swift-6.2-orange)](https://swift.org)
[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)](https://swift.org/package-manager)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2016%20%7C%20macOS%2014%20%7C%20tvOS%2016%20%7C%20watchOS%209%20%7C%20visionOS%201-lightgrey)](#platform-matrix)
[![Supply Chain](https://img.shields.io/badge/supply%20chain-SHA--pinned%20Actions%20%2B%20Dependabot-blue)](#production-checklist)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

InnoNetwork is a Swift package for type-safe networking on Apple platforms. The
root runtime package provides eight public products:

- `InnoNetwork` for request/response APIs
- `InnoNetworkAuthAWS` for the optional AWS SigV4 reference signer
- `InnoNetworkDownload` for download lifecycle management
- `InnoNetworkWebSocket` for connection-oriented realtime flows
- `InnoNetworkPersistentCache` for a conservative on-disk response cache
- `InnoNetworkTrust` for optional public-key pinning evaluation
- `InnoNetworkTestSupport` for consumer test targets
- `InnoNetworkOpenAPI` for generated-client transport support

## Product Selection Guide

| Product | Use When |
| --- | --- |
| `InnoNetwork` | You need the core typed request pipeline: interceptors, retry, refresh, circuit breaker, coalescing, cache, tracing, trust, and observability. |
| `InnoNetworkAuthAWS` | You need the optional AWS SigV4 reference signer. It is a single-shot signer, not an AWS SDK replacement. |
| `InnoNetworkDownload` | You need foreground/background download lifecycle management with pause, resume, retry, persistence, and event streams. |
| `InnoNetworkWebSocket` | You need long-lived bidirectional connections with heartbeat, reconnect, close taxonomy, and event delivery. |
| `InnoNetworkPersistentCache` | You want `ResponseCache` backed by disk with conservative RFC-aware storage guards and data protection. |
| `InnoNetworkOpenAPI` | Use `OpenAPIRequest` when generated or hand-written operations should run through the full `DefaultNetworkClient` pipeline. Use `InnoNetworkClientTransport` when an OpenAPI Runtime client needs a thin URLSession-backed transport and the full pipeline is not required. |
| `InnoNetworkTrust` | You need optional public-key pinning via `PublicKeyPinningEvaluator` and `TrustPolicy.custom(_:)`. |
| `InnoNetworkTestSupport` | You need consumer-test helpers such as `MockURLSession`, `StubNetworkClient`, or WebSocket recorders. Do not link it into production binaries. |

For the first 30 minutes, use `EndpointBuilder`. It gives you typed
responses, auth scopes, transport policy, and decoding without creating a
new type per endpoint. Reach for macros, streaming, multipart, WebSocket,
OpenAPI, or persistent cache after the basic request path is working.

The packages are built around Swift Concurrency, explicit transport
policies, and operational visibility that can scale from app prototypes
to production clients.

## Why InnoNetwork

Five things that differentiate this library from the usual URLSession
wrapper or Alamofire-style helper:

- **`typed throws` end-to-end** — `NetworkClient.request(_:)` is declared as
  `async throws(NetworkError)`, so call-sites get a concrete error type
  in `catch` without losing classification. Foreign errors are mapped at
  a single narrow boundary so the typed-throws invariant holds.
- **Phantom-typed HTTP headers** — `HTTPHeader<Value>` keys carry their
  value type at compile time (e.g. `.contentType`, `.authorization`,
  custom phantom keys). Typos and value/type mismatches fail at build,
  not at runtime.
- **`AuthScope` marker protocol** — every endpoint declares its auth
  requirement (`PublicAuthScope`, `AuthRequiredScope`, custom scopes)
  as a compile-time marker. The single-flight `RefreshTokenPolicy` only
  refreshes for endpoints that opted in.
- **Single-flight refresh + idempotency-aware retry** — concurrent 401s
  coalesce into one refresh call (`RefreshTokenCoordinator`). Retries
  follow RFC 9110: `GET`, `HEAD`, `OPTIONS`, and `TRACE` retry by default;
  unsafe methods retry only when an `Idempotency-Key` header is present.
  `Retry-After` is parsed for all three RFC 9110 formats with a
  maximum-clamp against malicious headers.
- **RFC 9111-aware cache adapter + first-class test support** — opt into
  `rfc9111Compliant(wrapping:)` to get the documented directive subset, or
  drop in `MockURLSession` / `VCRURLSession` / `StubNetworkClient` from
  `InnoNetworkTestSupport` (a top-level product, not a hidden helper).

See `API_STABILITY.md` for the Stable / Provisionally Stable contract
around each of these.

> ⚠️ **Apple platforms only by design.** InnoNetwork builds on URLSession, `OSAllocatedUnfairLock`, OSLog, and Network.framework, none of which match Apple-platform behaviour on Linux. Linux/server-side Swift is **not** a supported target. See [docs/PlatformSupport.md](docs/PlatformSupport.md) for the rationale and for guidance on sharing models with Linux server code (e.g. Vapor).

> 📚 **API Reference (DocC):** https://innosquadcorp.github.io/InnoNetwork/
> 🇰🇷 **한국어 문서:** [docs/ko/README.md](docs/ko/README.md)

## Choosing the Right Entry Point

InnoNetwork ships several layers. Pick the highest one that matches your
situation. Most app teams should start with `EndpointBuilder` and move down
only when an endpoint needs an owned type or a specialized transport.

```text
Do you just need method + path + headers + query/body + decoding?
├─ yes ─► EndpointBuilder
│          (e.g. EndpointBuilder<EmptyResponse, PublicAuthScope>.get("/users").decoding(User.self))
└─ no
   │
   Does the endpoint own interceptors, custom transport, multipart, or streaming?
   ├─ yes ─► APIDefinition / MultipartAPIDefinition / StreamingAPIDefinition
   │        (dedicated value type per endpoint)
   └─ no
      │
      Are you generating client code or want macro-generated endpoint structs?
      ├─ yes ─► InnoNetworkOpenAPI or InnoNetworkCodegen
      │        (advanced entry points; see "Advanced Surfaces" below)
      └─ no
         │
         Are you building an SDK or library wrapper that needs raw
         transport hooks (no decoding, no interceptors)?
         └─ yes ─► LowLevelNetworkClient (@_spi(GeneratedClientSupport))
                   — minor-version-mutable surface, see API_STABILITY.md
```

### When NOT to use InnoNetwork

- **Linux / server-side Swift.** InnoNetwork is Apple-platform-only by
  design (URLSession, `OSAllocatedUnfairLock`, OSLog, Network.framework).
  Use AsyncHTTPClient or a server framework on Linux.
- **One-off scripts where URLSession's three-line GET is enough.** The
  type-safety surface only pays off once you have shared interceptors,
  retry/coalescing/cache policies, or a fleet of endpoints.
- **Push-style protocols outside HTTP and WebSocket.** gRPC, MQTT,
  WebTransport are out of scope; pair InnoNetwork with a dedicated
  client.
- **You need synchronous APIs.** The package is built on Swift
  Concurrency end-to-end; there is no `DispatchQueue`/completion-handler
  fallback.

## Quick Start

### Install

```swift
dependencies: [
    // Recommended for app targets: pin to the current minor and accept
    // patch upgrades. Provisionally stable APIs may evolve across minor
    // bumps, so review CHANGELOG.md before adopting a new minor.
    .package(url: "https://github.com/InnoSquadCorp/InnoNetwork.git", .upToNextMinor(from: "4.0.0"))
]
```

> Use `from: "4.0.0"` (`.upToNextMajor`) only if you exclusively call
> the **Stable** ledger in `API_STABILITY.md`. Provisionally stable
> APIs (`EndpointBuilder`, `WebSocketCloseDisposition`, `DecodingInterceptor`,
> resilience policy surfaces, …) may change in any minor release.
>
> InnoNetwork also intentionally requires Swift 6.2+ and current Apple OS
> baselines (iOS 16, macOS 14, tvOS 16, watchOS 9, visionOS 1). That keeps
> the package aligned with strict concurrency and modern URLSession behavior,
> but apps with older deployment targets should keep a thin compatibility
> client until they can raise their platform floor.

### First 30 Minutes: EndpointBuilder

```swift
import Foundation
import InnoNetwork

struct User: Decodable, Sendable {
    let id: Int
    let name: String
}

struct CreatePost: Encodable, Sendable {
    let title: String
    let body: String
}

struct Post: Decodable, Sendable {
    let id: Int
    let title: String
}

let client = DefaultNetworkClient(
    configuration: .safeDefaults(
        baseURL: URL(string: "https://api.example.com/v1")!
    )
)

let user = try await client.request(
    EndpointBuilder<EmptyResponse, PublicAuthScope>
        .get("/users/1")
        .decoding(User.self)
)

let created = try await client.request(
    EndpointBuilder<EmptyResponse, PublicAuthScope>
        .post("/posts")
        .body(CreatePost(title: "Hello", body: "World"))
        .header("Idempotency-Key", value: UUID().uuidString)
        .decoding(Post.self)
)

print(user)
```

`EndpointBuilder` is the default onboarding path. It keeps the call site
compact while still flowing through retry, auth refresh, interceptors,
coalescing, cache, trust, tracing, and event observers configured on the
client.

```swift
let users = try await client.request(
    EndpointBuilder<EmptyResponse, PublicAuthScope>
        .get("/users")
        .query(["limit": 20])
        .decoding([User].self)
)

// form-url-encoded body
let token = try await client.request(
    EndpointBuilder<EmptyResponse, PublicAuthScope>
        .post("/login")
        .body(credentials)
        .transport(.formURLEncoded())
        .decoding(Token.self)
)

let me = try await client.request(
    EndpointBuilder<EmptyResponse, AuthRequiredScope>
        .get("/me")
        .decoding(User.self)
)
```

Use a dedicated `APIDefinition` type after the first path is working and an
endpoint needs a named contract, custom transport, per-endpoint interceptors,
multipart upload, or streaming response.

```swift
struct UserPatch: Encodable, Sendable {
    let displayName: String
}

struct UpdateUser: APIDefinition {
    typealias Parameter = UserPatch
    typealias APIResponse = User

    let parameters: UserPatch?
    var method: HTTPMethod { .patch }
    var path: String { "/me" }

    var transport: TransportPolicy<User> {
        .json(decoder: snakeCaseDecoder)
    }
}
```

`APIDefinition` exposes one transport-shape entry point — `transport: TransportPolicy<APIResponse>`.
The default is method-aware (`GET` → `.query()`, otherwise `.json()`), so most
hand-written endpoints don't override it. Use the `TransportPolicy` factories
when you need a different shape:

```swift
let patched = try await client.request(
    UpdateUser(parameters: UserPatch(displayName: "Taylor"))
)
```

### Advanced Surfaces

Use these after the first request path is stable:

- `@APIDefinition` / `#endpoint` in `InnoNetworkCodegen` when generated
  endpoint structs are worth the additional build-time dependency.
- `MultipartAPIDefinition` for upload payloads that need explicit part
  boundaries, metadata, and retry idempotency.
- `StreamingAPIDefinition` for SSE, NDJSON, logs, or other line-delimited
  long-lived responses.
- `InnoNetworkWebSocket` for bidirectional realtime flows.
- `InnoNetworkOpenAPI` for generated clients or OpenAPI Runtime transport.
- `InnoNetworkPersistentCache` when an API needs on-disk RFC-aware response
  caching beyond the in-memory default.

The `@APIDefinition` and `#endpoint` macros expand into the same value
types you would write by hand. They live in a separate
`Packages/InnoNetworkCodegen` package so root package consumers do not
resolve `swift-syntax`. Codegen distribution is experimental and supported
from a complete local checkout only: the root release tag does not vend the
nested product. Local workspace targets can opt in with the nested package,
then `import InnoNetworkCodegen`.

```swift
@APIDefinition(method: .get, path: "/users/{id}")
struct GetUser {
    let id: Int
    typealias APIResponse = User
}

let macroUser = try await client.request(GetUser(id: 1))
```

### Download

```swift
import Foundation
import InnoNetworkDownload

// Construct one DownloadManager per feature (or per policy). Each
// instance binds a unique URLSession identifier and DownloadConfiguration,
// so a media downloader can be WiFi-only and resumable while a documents
// downloader uses a different retry budget.
let manager = try DownloadManager.make(
    configuration: .safeDefaults(sessionIdentifier: "com.example.app.media")
)
let task = await manager.download(
    url: URL(string: "https://example.com/file.zip")!,
    toDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
)

for await event in await manager.events(for: task) {
    print(event)
}
```

> The 4.0.0 line removes the global `DownloadManager.shared` singleton —
> every feature now constructs and owns its own manager via
> ``DownloadManager.make(configuration:)`` with a unique session identifier.
> The throwing factory surfaces ``DownloadManagerError`` (e.g.,
> `duplicateSessionIdentifier`) directly so the failure mode is explicit.

#### Destination filename policy

`download(url:toDirectory:fileName:)` resolves the destination as:

- If `fileName:` is provided, it is trimmed and used only when it is a safe
  single path component.
- Otherwise the URL's last path component (`url.lastPathComponent`) is used
  when it is a safe single path component.
- Empty names, `.`, `..`, or names containing `/`, `\`, or NUL fall back to a
  generated `download-<UUID>` filename under `directory`.
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

let manager = WebSocketManager(configuration: .safeDefaults())
let task = await manager.connect(
    url: URL(string: "wss://echo.example.com/socket")!
)

for await event in await manager.events(for: task) {
    print(event)
}
```

## Products

### `InnoNetwork`

- async/await request execution
- type-safe `APIDefinition` modeling
- JSON, form-url-encoded, and multipart request support
- retry coordination, stable idempotency keys, auth refresh, request coalescing, response cache, and circuit breaker policies
- streaming-by-default inline response buffering and public `RequestExecutionPolicy` hooks
- W3C `traceparent` propagation and curl command export helpers
- phantom auth scopes through `EndpointBuilder`, `PublicAuthScope`, and `AuthRequiredScope`
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

### `InnoNetworkPersistentCache`

- actor-backed `ResponseCache` implementation for on-disk GET caching
- default 50 MB / 1000 entry / 5 MB per-entry caps
- refuses authenticated, `Cache-Control: private`, and `Set-Cookie` responses by default
- applies `.completeUnlessOpen` data protection to cache files by default
- `dataProtectionClass: .none` requests `NSFileProtectionNone` for cache-owned paths
- versioned index and hashed body files with corrupt-entry eviction

### `InnoNetworkOpenAPI`

- `OpenAPIRequest` for running generated or hand-written operations through the full `DefaultNetworkClient` pipeline
- `OpenAPIRestOperation` bridge for generated operation metadata
- `InnoNetworkClientTransport` for thin `swift-openapi-runtime` transport when URLSession-level behavior is enough

### `InnoNetworkTrust`

- public-key pinning evaluator split from the core product
- `PublicKeyPinningPolicy` host rules and SPKI matching
- `TrustPolicy.custom(_:)` integration for HTTP and WebSocket trust evaluation

### `InnoNetworkTestSupport`

- `MockURLSession` for deterministic request capture in consumer tests
- `StubNetworkClient` for testing app layers without touching transport
- `WebSocketEventRecorder` for websocket integration assertions
- intended for test targets, not production binaries

### Separate `InnoNetworkCodegen` Package

- optional `@APIDefinition` and `#endpoint` macros
- depends on `swift-syntax` from `Packages/InnoNetworkCodegen` only
- keeps `swift-syntax` out of the root `InnoNetwork` package dependency graph
- experimental local-checkout distribution; the root release tag does not vend
  the nested product
- follows the root deployment floors: iOS 16, macOS 14, tvOS 16, watchOS 9,
  and visionOS 1

## Platform Matrix

- iOS 16.0+
- macOS 14.0+
- tvOS 16.0+
- watchOS 9.0+
- visionOS 1.0+
- Swift 6.2+

The package intentionally targets current Apple platform releases. That lets the codebase rely on modern Swift Concurrency semantics, stricter Sendable checking, and the latest URLSession and platform APIs without compatibility shims.

## Protocol Buffers

Protocol Buffers support moved to the separate `InnoNetworkProtobuf` package. Consumers that need protobuf request and response modeling must add `InnoNetworkProtobuf` alongside `InnoNetwork` in the same package manifest.

```swift
dependencies: [
    .package(url: "https://github.com/InnoSquadCorp/InnoNetwork.git", from: "4.0.0"),
    .package(url: "https://github.com/InnoSquadCorp/InnoNetworkProtobuf.git", branch: "main")
]
```

`InnoNetworkProtobuf` is being prepared for its first tagged release; until
then, follow its `main` branch.

## Configuration

Use `safeDefaults` as the secure baseline for prototypes, tests, and clients
that already own retry/cache policy elsewhere. Use
`recommendedForProduction(baseURL:)` for app-facing production clients: it
keeps the safe baseline and adds conservative retry, circuit-breaker,
idempotency-key, and body-size guardrails. Use `advanced` only when you need
explicit operational tuning.

```swift
import Foundation
import InnoNetwork
import InnoNetworkDownload
import InnoNetworkWebSocket

let network = NetworkConfiguration.recommendedForProduction(
    baseURL: URL(string: "https://api.example.com")!
)

let download = DownloadConfiguration.safeDefaults(
    sessionIdentifier: "com.example.app.downloads"
)

let socket = WebSocketConfiguration.safeDefaults()

let tunedNetwork = NetworkConfiguration.advanced(
    baseURL: URL(string: "https://api.example.com")!,
    resilience: ResiliencePack(
        retry: ExponentialBackoffRetryPolicy(),
        coalescing: .getOnly
    ),
    cache: CachePack(
        responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
        responseCache: InMemoryResponseCache()
    ),
    transport: TransportPack(
        timeout: 30,
        redirectPolicy: DefaultRedirectPolicy(),
        trustPolicy: .systemDefault
    )
)
```

Auth refresh, coalescing, caching, and circuit breaking are opt-in. The
request execution pipeline stays internal; public configuration exposes only
the built-in policies.

### Transport security defaults

Core request clients default to HTTPS-only construction and safe redirect
handling:

- `DefaultRedirectPolicy` rejects HTTPS-to-HTTP downgrade redirects.
- Cross-origin 307/308 redirects cannot automatically replay unsafe methods
  such as POST, PUT, PATCH, or DELETE.
- Other cross-origin redirects strip common authorization, cookie, API-key,
  CSRF/session-token, and temporary AWS credential headers. Add proprietary
  credential carriers with `additionalSensitiveHeaders`; built-in protection
  remains enabled.
- Plain `http://` base URLs fail before transport unless the client opts in
  with `allowsInsecureHTTP = true`.
- Base URLs with embedded `user:password@host` credentials or fragments are
  rejected; put credentials in an interceptor or `RefreshTokenPolicy` instead.

```swift
let redirectPolicy = DefaultRedirectPolicy(
    additionalSensitiveHeaders: ["X-Tenant-Secret"]
)
```

Two explicit compatibility switches exist for controlled legacy or LAN
environments. Enabling them weakens the default boundary, so scope the policy
to a dedicated client; sensitive headers are still stripped across origins:

```swift
let controlledLegacyRedirects = DefaultRedirectPolicy(
    allowsHTTPSDowngrade: true,
    allowsCrossOriginUnsafeMethodRedirects: true
)
```

Keep the HTTP opt-in scoped to local development or a controlled LAN-only
client:

```swift
let local = NetworkConfiguration.advanced(
    baseURL: URL(string: "http://localhost:8080")!,
    transport: TransportPack(allowsInsecureHTTP: true)
)
```

```swift
let refreshPolicy = RefreshTokenPolicy(
    currentToken: { try await tokenStore.currentAccessToken() },
    refreshToken: { try await authService.refreshAccessToken() }
)

let client = DefaultNetworkClient(
    configuration: .advanced(
        baseURL: URL(string: "https://api.example.com")!,
        resilience: ResiliencePack(
            circuitBreaker: CircuitBreakerPolicy(failureThreshold: 3)
        ),
        auth: AuthPack(refreshToken: refreshPolicy)
    )
)
```

### Tag-based cancellation

`request(_:tag:)` and `upload(_:tag:)` register the dispatched task under a
`CancellationTag` so a screen, feature, or user session can drop just its own
requests when it goes away. `cancelAll()` continues to drain every in-flight
request when no granularity is required.

```swift
let feed: CancellationTag = "feed"

async let posts = client.request(GetPosts(), tag: feed)
async let banner = client.request(GetBanner(), tag: feed)

// User leaves the feed screen — only feed-tagged requests stop:
await client.cancelAll(matching: feed)
```

Untagged requests, and requests registered with a different tag, are left
alone by `cancelAll(matching:)`.

### Response cache and Vary handling

The opt-in `ResponseCachePolicy` honours the response `Vary` header
automatically (RFC 9111 §4.1):

- `Vary: *` responses are not stored — the cache cannot prove a future
  request would match.
- A concrete `Vary` header (for example `Vary: Accept-Language`) captures the
  named request headers when the response is stored. The next lookup matches
  only when those same header values are present, so two clients with
  different `Accept-Language` values do not see each other's payloads.
- Responses without a `Vary` header use the existing per-identity key
  (Authorization, etc.) when the response is eligible for storage.
- GET responses with whole-response cacheable status codes (`200`, `203`,
  `204`, `300`, `301`, `308`, `404`, `405`, `410`, `414`, and `501`) can be
  stored; `206 Partial Content` is excluded.
- `Cache-Control: no-store` and `Cache-Control: private` invalidate the current
  cache key and skip writes, including quoted directives such as
  `private="Set-Cookie, Authorization"`. `Cache-Control: no-cache` stores the
  response but forces revalidation before every reuse.
- Responses to requests carrying `Authorization` are stored only when the
  origin explicitly permits it with `Cache-Control: public`, `must-revalidate`,
  or `s-maxage`.
- Successful unsafe methods (`POST`, `PUT`, `PATCH`, `DELETE`, and unknown
  methods) invalidate every cached variant for the normalized target URI per
  RFC 9111 §4.4. `.disabled` and `.networkOnly` still leave cache metadata
  untouched.

`InnoNetworkPersistentCache` is **not** a full RFC 9111 cache by
default — storage directives are enforced by the executor, while
the freshness window is normally driven by `ResponseCachePolicy`
(`cacheFirst(maxAge:)` etc.). Clients that need directive-aware
behavior (`no-store` suppression, `must-revalidate` stale denial,
server `max-age` clamping, `Expires` fallback, and `Last-Modified` heuristic freshness)
should wrap their policy with
`ResponseCachePolicy.rfc9111Compliant(wrapping:)`:

```swift
let cache = CachePack(
    responseCachePolicy: .rfc9111Compliant(
        wrapping: .cacheFirst(maxAge: .seconds(300))
    ),
    responseCache: InMemoryResponseCache()
)
```

See `docs/rfcs/RFC9111-Compliance.md` for the exact directive coverage
and the trade-offs.

### Optional Macros

Add the separate `InnoNetworkCodegen` package only when you want compile-time
endpoint helpers. Inside this repository, examples use a local path dependency
to `Packages/InnoNetworkCodegen`; published consumers should depend on the
dedicated codegen package once it is distributed independently.

```swift
import InnoNetwork
import InnoNetworkCodegen

@APIDefinition(method: .get, path: "/users/{id}")
struct GetUser {
    let id: Int
    typealias APIResponse = User
}

let endpoint = #endpoint(.get, "/users/1", as: User.self)
```

The macro saves boilerplate for the simple, common endpoint shape:

```swift
// Hand-written
struct GetUser: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = User

    let id: Int
    var method: HTTPMethod { .get }
    var path: String { "/users/\(id)" }
}

// Macro
@APIDefinition(method: .get, path: "/users/{id}")
struct GetUser {
    let id: Int
    typealias APIResponse = User
}
```

Use the macro when the endpoint is method + path placeholders + standard
decoding. Keep a hand-written `APIDefinition` when the endpoint owns custom
parameters, interceptors, multipart, streaming, non-standard decoding, or an
SDK surface where generated witnesses would hide important policy choices.

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
    case .configuration(reason: .invalidBaseURL(let url)):
        print("Invalid base URL: \(url)")
    case .configuration(reason: .invalidRequest(let message)):
        print("Invalid request configuration: \(message)")
    case .configuration(reason: .offline(let message)):
        print("Offline: \(message)")
    case .statusCode(let response):
        print("Unexpected status code: \(response.statusCode)")
    case .decoding(let stage, let underlying, _):
        print("Decoding failed (\(stage)): \(underlying)")
    case .trustEvaluationFailed(let reason):
        print("Trust evaluation failed: \(reason)")
    case .cancelled:
        print("Request cancelled")
    default:
        print(error)
    }
}
```

`.configuration(reason: .invalidRequest(...))` usually means request shape and policy do not match. Common examples are:

- sending a top-level scalar or array query without `queryRootKey`
- mismatching `contentType` and request payload semantics
- putting query or fragment components directly in an endpoint `path`
- using a malformed multipart payload

Request construction follows a fixed contract: endpoint paths are appended after
the `baseURL` path even when they start with `/`; endpoint paths must not include
`?` or `#`; query values must flow through `parameters` and `queryEncoder`; and
`Content-Type` is attached only for body, multipart, or file-upload payloads.
Header precedence is library defaults, endpoint headers, automatic body
`Content-Type`, request interceptors, then `RefreshTokenPolicy` authorization.

Choose `HTTPHeaders.add` only when a repeated field value is intentional, such
as accept negotiation or other comma-combinable metadata. Prefer
`HTTPHeaders.update`, subscript assignment, or `URLRequest.setValue` for
single-value request fields such as `Authorization`, `Content-Type`, `Cookie`,
and `Host`; `URLRequest.headers` and `URLSessionConfiguration.headers` apply
single-value names with last-write-wins semantics while preserving repeatable
header values.

For operational tuning, see [Examples](Examples/README.md) and [API Stability](API_STABILITY.md).
Teams migrating an existing client can start with
[Migration Guides](docs/MigrationGuides.md), then use the focused
[Alamofire cookbook](docs/MigrationFromAlamofire.md) or
[Moya cookbook](docs/MigrationFromMoya.md) for 30-minute before/after
examples.

## Stability

Public releases follow semantic versioning starting with `4.0.0`, the first
public release of the 4.x line.

- Stable public API: [API_STABILITY.md](API_STABILITY.md)
- Release rules and compatibility policy: [docs/RELEASE_POLICY.md](docs/RELEASE_POLICY.md)
- Migration expectations: [docs/MIGRATION_POLICY.md](docs/MIGRATION_POLICY.md)

`safeDefaults` is the recommended public path. `default` aliases are available
as `safeDefaults` aliases, but new examples and new integrations should prefer
`safeDefaults`.

`request` and `upload` are the recommended request execution APIs. Use
`RequestExecutionPolicy` to observe or wrap a transport attempt and to adapt
its response. Execution policies cannot replace the executor-owned request;
use `RequestInterceptor` for URL, header, or body mutation. SPI lower-level
execution hooks remain outside the stable public contract.

For long-lived line-delimited transports (Server-Sent Events, NDJSON, log
streams), use `DefaultNetworkClient.stream(_:)` together with a
`StreamingAPIDefinition`. To cancel every in-flight request and stream
(for example, on logout or backgrounding), call
`DefaultNetworkClient.cancelAll()`. See
[docs/releases/4.0.0.md](docs/releases/4.0.0.md) for full release details.

## Benchmarks

The repository includes a dedicated benchmark runner for quick local comparisons.

```bash
swift run -c release InnoNetworkBenchmarks --quick
swift run -c release InnoNetworkBenchmarks --json-path /tmp/innonetwork-bench.json
```

Benchmark governance, baseline policy, and CI posture are documented in [Benchmarks/README.md](Benchmarks/README.md).

Current guarded quick-baseline highlights from
[`Benchmarks/Baselines/default.json`](Benchmarks/Baselines/default.json)
(`generatedAt`: `2026-05-02T18:40:44Z`):

| Area | Guarded benchmark | Iterations | Baseline ops/sec |
| --- | --- | ---: | ---: |
| Request pipeline | `client/request-pipeline` | 2,000 | 5,225 |
| Request coalescing | `client/request-coalescing-shared-get` | 2,000 | 3,891 |
| Cache lookup | `cache/response-cache-lookup` | 200,000 | 466,773 |
| Cache revalidation | `cache/response-cache-revalidation` | 200,000 | 1,285,328 |
| Event fan-out | `events/task-event-fanout-single` | 2,000 | 18,124 |
| Download restore | `persistence/download-persistence-restore` | 50 | 46 |
| WebSocket close classification | `websocket/websocket-close-disposition-classify` | 500,000 | 3,980,702 |

## Production Checklist

Operational items to verify before shipping a client built on InnoNetwork.

### Trust & Transport Security

- **TLS pinning rotation.** When using `TrustPolicy.custom(PublicKeyPinningEvaluator(...))`
  (from `import InnoNetworkTrust`), ship at least two pins (current + next) and document the
  rotation cadence so the app keeps validating after certificate replacement. Consider
  feature-gated rollback to `.systemDefault` for emergency recovery.
- **Redirect credential leakage.** Keep the default `DefaultRedirectPolicy`
  unless you have a stricter allowlist. Any custom policy must preserve the
  cross-origin stripping of `Authorization`, `Cookie`, and
  `Proxy-Authorization`.
- **Pinning host matching.** Keep the default `.unionAllMatches` if parent-domain pins should
  act as backup pins for subdomains. Use `.mostSpecificHost` when `example.com` and
  `api.example.com` pins must be operated as separate trust scopes.
- **App Transport Security (ATS).** The default `safeDefaults` configuration assumes ATS is
  enabled. Avoid `NSAllowsArbitraryLoads` in production `Info.plist`. If a non-HTTPS host is
  unavoidable, scope an `NSExceptionDomains` entry to that host only and set
  `allowsInsecureHTTP = true` only on the matching client configuration.
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
- **Failure payload capture.** `NetworkError.decoding(stage:, underlying:, response:)` carries a `Response`;
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
- **Retry idempotency.** The built-in retry policy retries `GET`/`HEAD` by
  default. `POST`, upload, and multipart requests retry only when they carry an
  `Idempotency-Key`, unless the client opts into `.methodAgnostic`.
- **Auth refresh.** Prefer `RefreshTokenPolicy` over response interceptors for
  `401` refresh + replay. The policy single-flights concurrent refreshes and
  replays each fully adapted request at most once.
- **Cache and circuit breaker.** Enable `ResponseCachePolicy` and
  `CircuitBreakerPolicy` per client only after deciding the cache freshness
  and host-failure budget for that API. Cache keys include an `Authorization`
  fingerprint, `Cookie`/credential-like headers are fingerprinted when present,
  and `Accept-Language` is included by default; the response `Vary` header
  further refines lookups, `Vary: *` responses are skipped, and
  `Cache-Control: no-store` / `private` / `no-cache` are honoured.
- **WebSocket reconnect cap.** `maxReconnectAttempts` limits successive automatic attempts.
  After exhaustion, surface the failure to the UI rather than reconnect on every app
  foreground.

### Push & Lifecycle Refresh

- **Background fetch friendly.** Streaming or websocket products expect explicit
  `disconnect()` calls before app suspension. Implement `applicationDidEnterBackground`
  cleanup; the OS will not gracefully close sockets on your behalf.
- **Token refresh.** Let `RefreshTokenPolicy` apply the current access token and
  own `401` refresh + replay. Keep request signing, tenant headers, request IDs,
  and other non-refresh metadata in `RequestInterceptor`s.

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
- Policy Interactions: [docs/PolicyInteractions.md](docs/PolicyInteractions.md)
- Operational Guides: [docs/OperationalGuides.md](docs/OperationalGuides.md)
- Platform Support: [docs/PlatformSupport.md](docs/PlatformSupport.md)
- Release Policy: [docs/RELEASE_POLICY.md](docs/RELEASE_POLICY.md)
- Migration Policy: [docs/MIGRATION_POLICY.md](docs/MIGRATION_POLICY.md)
- Migration Guides: [docs/MigrationGuides.md](docs/MigrationGuides.md)
- Alamofire Migration Cookbook: [docs/MigrationFromAlamofire.md](docs/MigrationFromAlamofire.md)
- Moya Migration Cookbook: [docs/MigrationFromMoya.md](docs/MigrationFromMoya.md)
- DocC Deployment: [docs/DocC_Deployment.md](docs/DocC_Deployment.md)
- Query Encoding Reference: [docs/QueryEncoding.md](docs/QueryEncoding.md)
- WebSocket Lifecycle: [docs/WebSocketLifecycle.md](docs/WebSocketLifecycle.md)
- Task Ownership: [docs/TaskOwnership.md](docs/TaskOwnership.md)
- Release Notes: [docs/releases/4.0.0.md](docs/releases/4.0.0.md)
- Roadmap: [docs/ROADMAP.md](docs/ROADMAP.md)
- 한국어 문서: [docs/ko/README.md](docs/ko/README.md)

## Adoption

Verified production users are listed only after maintainers have explicit
permission to name the company or team publicly.

If you use InnoNetwork in production, please open a pull request with the
company or team name, the modules in use (Core / Download / WebSocket /
PersistentCache), and one line about what helped your adoption decision.

## Support

InnoNetwork follows a lightweight maintainer model.

- Support policy: [SUPPORT.md](SUPPORT.md)
- Contributing guide: [CONTRIBUTING.md](CONTRIBUTING.md)
- Security reporting: [SECURITY.md](SECURITY.md)
- Changelog: [CHANGELOG.md](CHANGELOG.md)
- Code of Conduct: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)

## License

MIT. See [LICENSE](LICENSE).
