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

> **Release status:** `4.0.0` is the latest tagged stable release and the
> actively security-supported line. The `main` branch is an unreleased,
> source-breaking 5.0 preview; no `5.0.0` tag exists yet. Unless a section says
> otherwise, the API examples below describe the current `main` preview and
> may not compile against 4.x.

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

For application API catalogs, start with an explicit endpoint struct and the
default-enabled `@APIDefinition` macro. The struct remains the source of truth;
the macro derives repetitive witnesses and fails the build when method, path,
payload, response, or auth declarations are incomplete. Use `EndpointBuilder`
for one-off or runtime-composed requests that do not deserve a named contract.

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
- **Explicit session authentication** — every endpoint declares
  `SessionAuthentication` as `.anonymous`, `.optional`, or `.required`.
  Required endpoints fail before transport when no refresh policy can provide
  a token; the single-flight `RefreshTokenPolicy` only refreshes endpoints
  that opted in.
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

InnoNetwork ships several layers. Pick the highest one that preserves the
contract your application needs. Most app teams should use macro-assisted,
explicit `APIDefinition` structs for their API catalog.

```text
Does this endpoint belong in the application's named API catalog?
├─ yes ─► @APIDefinition on an explicit struct
│          (the struct owns inputs, APIResponse, and any custom policy)
└─ no
   │
   Is it a one-off or runtime-composed HTTP request?
   ├─ yes ─► EndpointBuilder
   └─ no
      │
      Does it need multipart, streaming, or generated OpenAPI transport?
      ├─ yes ─► MultipartAPIDefinition / StreamingAPIDefinition / InnoNetworkOpenAPI
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

For released applications, consume the tagged 4.x line:

```swift
dependencies: [
    .package(
        url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
        .upToNextMajor(from: "4.0.0")
    )
]
```

To evaluate the breaking 5.0 preview, opt into `main` explicitly. Prefer a
specific revision in CI so preview updates are deliberate:

```swift
dependencies: [
    .package(
        url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
        branch: "main"
    )
]
```

> Do not treat `main` as a released SemVer dependency. The draft Stable /
> Provisionally Stable ledger in `API_STABILITY.md` becomes the 5.x contract
> only when `5.0.0` is tagged.
>
> InnoNetwork also intentionally requires Swift 6.2+ and current Apple OS
> baselines (iOS 16, macOS 14, tvOS 16, watchOS 9, visionOS 1). That keeps
> the package aligned with strict concurrency and modern URLSession behavior,
> but apps with older deployment targets should keep a thin compatibility
> client until they can raise their platform floor.

### First 30 Minutes: Explicit Endpoints, Macro-Assisted (5.0 Preview)

The following current API uses the unreleased 5.0 preview. For the tagged 4.x
API, start with the 4.0 release and migration documents instead.

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

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
struct GetUser {
    typealias APIResponse = User

    let id: Int
}

@APIDefinition(method: .post, path: "/posts", auth: .anonymous)
struct CreatePostEndpoint {
    typealias APIResponse = Post

    let body: CreatePost
}

let client = DefaultNetworkClient(
    configuration: .safeDefaults(
        baseURL: URL(string: "https://api.example.com/v1")!
    )
)

let user = try await client.request(GetUser(id: 1))
let created = try await client.request(
    CreatePostEndpoint(body: CreatePost(title: "Hello", body: "World"))
)

print(user)
```

`GetUser` and `CreatePostEndpoint` remain ordinary, explicit value types. The
macro adds `APIDefinition` conformance, `method`, `path`, and the simple
`Parameter` / `parameters` witnesses. `APIResponse` stays visible, and every
attribute must choose `auth: .anonymous`, `.optional`, or `.required`; the
macro never guesses a security boundary. A stored `query` is inferred for GET
and HEAD; a stored `body` is inferred only for POST, PUT, PATCH, and DELETE.
OPTIONS, CONNECT, TRACE, custom, and dynamic methods require a complete
`Parameter` + `parameters` payload contract.

Path placeholder values must be non-optional. Direct `T?`, `Optional<T>`, and
`Swift.Optional<T>` spellings fail during macro expansion; aliases that resolve
to an Optional fail at the generated call site with the same targeted guidance
to unwrap the value and define its nil behavior.

Use `EndpointBuilder` when a request is genuinely local or runtime-composed:

```swift
let previewPath = "/users/preview"
let preview = try await client.request(
    EndpointBuilder<EmptyResponse>
        .get(previewPath)
        .authentication(.anonymous)
        .decoding(User.self)
)
```

For a custom payload, declare the complete `Parameter` + `parameters` pair.
It is the authoritative escape hatch; headers, interceptors, transport,
decoding, and policy overrides likewise stay explicit on the struct.

```swift
struct UserPatch: Encodable, Sendable {
    let displayName: String
}

@APIDefinition(method: .patch, path: "/me", auth: .anonymous)
struct UpdateUser {
    typealias Parameter = UserPatch
    typealias APIResponse = User

    let patch: UserPatch

    var parameters: Parameter? { patch }

    var transport: TransportPolicy<User> {
        .json(decoder: snakeCaseDecoder)
    }
}
```

`APIDefinition` exposes one transport-shape entry point —
`transport: TransportPolicy<APIResponse>`. For macro-assisted simple payloads,
GET and HEAD use `.query()`, while POST, PUT, PATCH, and DELETE use `.json()`.
Other methods keep their payload and any non-default transport explicit on the
endpoint struct.

```swift
let patched = try await client.request(
    UpdateUser(patch: UserPatch(displayName: "Taylor"))
)
```

The macro comes from `import InnoNetwork` through the package's default
`Macros` trait. No separate codegen package or import is required. Consumers
that never use macros can set `traits: []` on the InnoNetwork package
dependency; this removes the macro declaration and compiler plug-in products
from their target graph and compilation. SwiftPM may still resolve or fetch
the package-level `swift-syntax` dependency while evaluating the manifest.
Traits are unified per package across the resolved graph, so every dependency
path must keep `Macros` disabled; another dependency that enables the default
trait re-enables it for that package instance.

### Advanced Surfaces

Use these after the first request path is stable:

- `MultipartAPIDefinition` for upload payloads that need explicit part
  boundaries, metadata, and retry idempotency.
- `StreamingAPIDefinition` for SSE, NDJSON, logs, or other line-delimited
  long-lived responses.
- `InnoNetworkWebSocket` for bidirectional realtime flows.
- `InnoNetworkOpenAPI` for generated clients or OpenAPI Runtime transport.
- `InnoNetworkPersistentCache` when an API needs on-disk RFC-aware response
  caching beyond the in-memory default.

### Download

```swift
import Foundation
import InnoNetworkDownload

// Construct one DownloadManager per feature (or per policy). Each
// instance binds a unique URLSession identifier and DownloadConfiguration,
// so a media downloader can be WiFi-only and resumable while a documents
// downloader uses a different retry budget.
let manager = try DownloadManager(
    configuration: .safeDefaults(sessionIdentifier: "com.example.app.media")
)
let task = await manager.download(
    url: URL(string: "https://example.com/file.zip")!,
    toDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
)

for await event in await manager.events(for: task) {
    print(event)
}

// The owner closes the lifecycle explicitly. This cancels and removes
// persisted in-flight work, drains admitted callbacks/events, and releases
// the manager's session and persistence scope.
await manager.shutdown()
```

`safeDefaults` and `advanced` use the secure foreground session mode. Call
`backgroundTransfersEnabled()` on the finished configuration only when
transfers must continue outside the app process; see the background-mode
redirect trade-off below and in the
[background download guide](Sources/InnoNetworkDownload/InnoNetworkDownload.docc/Articles/BackgroundDownloads.md).

> The 4.0.0 line removes the global `DownloadManager.shared` singleton —
> every feature now constructs and owns its own manager via
> ``DownloadManager/init(configuration:)`` with a unique session identifier.
> The throwing initializer surfaces ``DownloadManagerError`` (e.g.,
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
- explicit `.anonymous`, `.optional`, and `.required` session authentication
  through `APIDefinition` and `EndpointBuilder`
- trust policy support and request lifecycle observability

### `InnoNetworkDownload`

- foreground and background download orchestration
- pause, resume, retry, and listener retention across retries
- append-log persistence for durable task restoration
- `AsyncStream` and listener-based event delivery

### `InnoNetworkWebSocket`

- heartbeat and pong timeout handling
- reconnect policies with handshake-aware close taxonomy
- listener retention across automatic reconnect transport generations
- explicit `retry(_:)` returns a fresh task and pre-registered bounded event
  stream in `WebSocketRetryResult`, preventing immediate retry events from
  racing consumer registration
- `AsyncStream` and listener-based event delivery

### `InnoNetworkPersistentCache`

- actor-backed `ResponseCache` implementation for on-disk GET caching
- default 50 MB / 1000 entry / 5 MB per-entry caps
- refuses authenticated, `Cache-Control: private`, and `Set-Cookie` responses by default
- applies `.completeUntilFirstUserAuthentication` data protection to cache files by default on iOS-family platforms
- excludes cache-owned indexes, keys, and bodies from backup while leaving the caller-supplied directory root unchanged
- `dataProtectionClass: .none` requests `NSFileProtectionNone` for cache-owned paths on iOS-family platforms
- versioned index and hashed body files with corrupt-entry eviction

### `InnoNetworkOpenAPI`

- `OpenAPIRequest` for running generated or hand-written operations through the full `DefaultNetworkClient` pipeline
- `OpenAPIRestOperation` bridge for generated operation metadata
- `InnoNetworkClientTransport` for thin `swift-openapi-runtime` transport when URLSession-level behavior is enough
- generated-client redirects use the default redirect policy plus per-hop URL
  admission; background URLSession is rejected because Foundation bypasses
  that callback

### `InnoNetworkTrust`

- public-key pinning evaluator split from the core product
- `PublicKeyPinningPolicy` host rules and SPKI matching
- `TrustPolicy.custom(_:)` integration for HTTP and WebSocket trust evaluation

### `InnoNetworkTestSupport`

- `MockURLSession` for deterministic request capture in consumer tests
- `StubNetworkClient` for testing app layers without touching transport
- `WebSocketEventRecorder` for websocket integration assertions
- intended for test targets, not production binaries

### Macro Support

- default-enabled `@APIDefinition(method:path:auth:)` from `import InnoNetwork`
- explicit endpoint structs remain the source of truth
- `APIResponse` and authentication intent stay mandatory and visible
- simple GET/HEAD `query` or POST/PUT/PATCH/DELETE `body` properties derive
  payload witnesses
- OPTIONS, CONNECT, TRACE, custom, and dynamic methods require a complete
  `Parameter` + `parameters` payload contract
- complete `Parameter` + `parameters` declarations remain authoritative
- compile-time diagnostics reject incomplete or ambiguous definitions
- `traits: []` excludes macro APIs and compiler plug-in compilation for
  core-only consumers

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
    .package(url: "https://github.com/InnoSquadCorp/InnoNetwork.git", branch: "main"),
    .package(url: "https://github.com/InnoSquadCorp/InnoNetworkProtobuf.git", branch: "main")
]
```

`InnoNetworkProtobuf` is being prepared for its first tagged release; until
then, follow its `main` branch. This pair is a preview configuration, not a
tagged production dependency.

## Configuration

Use `safeDefaults` as the secure baseline for prototypes, tests, and clients
that already own retry/cache policy elsewhere. Use
`recommendedForProduction(baseURL:)` for app-facing production clients: it
keeps the safe baseline and adds conservative retry, circuit-breaker,
idempotency-key, and body-size guardrails. Use `advanced` only when you need
explicit operational tuning.

In the 5.0 preview, `safeDefaults`, the `advanced` preset, and
`recommendedForProduction` cap collected responses, including file-upload
responses, at 5 MiB by default.
Set an explicit `.streaming(maxBytes: nil)` or `.buffered(maxBytes: nil)` only
when an unbounded response is a deliberate, reviewed choice.

For inline requests, `.buffered(maxBytes:)` validates the size only after
`URLSession.data(for:)` has buffered the response; it bounds what proceeds to
cache storage and decoding, not peak transport buffering. Bounded streaming
and bounded file-upload responses inspect the body while it arrives and cancel
the underlying task as soon as a known or observed limit is exceeded. A
bounded file upload therefore uses a streamed data task with an explicit
`Content-Length`; an explicitly unbounded file upload preserves the native
file-backed upload-task path.

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

Core request clients and downloads default to HTTPS-only construction and safe
redirect handling:

- `DefaultRedirectPolicy` rejects HTTPS-to-HTTP downgrade redirects.
- Any cross-origin redirect that retains an unsafe method such as POST, PUT,
  PATCH, or DELETE is rejected, including nonstandard 301/302 proposals as
  well as 307/308 replay.
- Other cross-origin redirects strip every header prepared on the original
  request, plus common authorization, cookie, API-key, CSRF/session-token, and
  temporary AWS credential headers. Core URLSession transports also clear
  every value from `URLSessionConfiguration.httpAdditionalHeaders` on a
  cross-origin hop so Foundation cannot re-inject a removed session default;
  same-origin redirects retain those values. Register proprietary credential
  carriers with `additionalSensitiveHeaders` when using the policy outside
  that transport integration; built-in protection remains enabled.
- Plain `http://` base URLs fail before transport unless the client opts in
  with `allowsInsecureHTTP = true`.
- Foreground downloads — the configuration default — re-admit every redirect
  target through the same URL guard. A rejected
  downgrade, unsafe cross-origin replay, or traversal target fails as
  `DownloadError.invalidURL` without consuming retry budget.
- `backgroundTransfersEnabled()` is the one explicit opt-in that trades that
  per-hop preflight for process-independent continuation. Foundation follows
  background redirects automatically without consulting the redirect
  delegate. Initial and final URLs are still validated where Foundation
  exposes them, but that validation cannot prevent an intermediate background
  redirect from being contacted.
- Download progress callbacks are coalesced before entering the actor, while
  completion callbacks remain lossless and FIFO. Final completed, failed, and
  cancelled events seal their task partition so late progress cannot displace
  the terminal outcome under a bounded overflow policy.
- App-facing download callbacks use a per-task ordered delivery lane. A slow
  progress or terminal callback does not hold the URLSession delegate FIFO or
  delay the system background-session completion handler. The pre-transport
  `waiting` and `downloading` state callbacks remain admission hooks, and
  external `shutdown()` still drains every accepted callback before returning.
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

### Macro-First Endpoint Definitions

The default `Macros` trait exposes `@APIDefinition` directly from
`import InnoNetwork`:

```swift
import InnoNetwork

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
struct GetUser {
    typealias APIResponse = User

    let id: Int
}
```

The attribute derives conformance, method, percent-encoded path,
`sessionAuthentication`, and simple payload witnesses. It does not hide the
response model or endpoint policy: `APIResponse`, stored inputs, headers,
interceptors, transport, and decoding choices remain visible on the struct. A
complete `Parameter` + `parameters` pair overrides body/query inference for
advanced endpoints.

Invalid definitions fail at compile time with a diagnostic and, where safe, a
Fix-It. The 4.x `#endpoint` expression macro is removed; use `EndpointBuilder`
when a request does not need an explicit endpoint type.

See [Using Macros](Sources/InnoNetwork/InnoNetwork.docc/Articles/UsingMacros.md)
for payload rules, diagnostics, and core-only trait opt-out.

## Error Handling

InnoNetwork favors explicit transport errors over opaque failures.

```swift
do {
    let user = try await client.request(GetUser(id: 42))
    print(user)
} catch {
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

Public releases follow semantic versioning. `4.0.0` is the latest tagged
compatibility baseline. The current `main` branch is preparing the breaking
5.0 contract, but that contract is still a preview until `5.0.0` is tagged.

- Stable public API: [API_STABILITY.md](API_STABILITY.md)
- Release rules and compatibility policy: [docs/RELEASE_POLICY.md](docs/RELEASE_POLICY.md)
- Migration expectations: [docs/MIGRATION_POLICY.md](docs/MIGRATION_POLICY.md)

`safeDefaults` is the canonical secure entry point. The duplicate legacy
configuration aliases are absent from the 5.0 preview; examples and new
integrations use the named factory so the selected policy is visible.

`NetworkClient.request` and `UploadNetworkClient.upload` are the recommended
capability boundaries (`DefaultNetworkClient` supports both). Use
`RequestExecutionPolicy` to observe or wrap a transport attempt and to adapt
its response. Execution policies cannot replace the executor-owned request;
use `RequestInterceptor` for URL, header, or body mutation. SPI lower-level
execution hooks remain outside the stable public contract.

For long-lived line-delimited transports (Server-Sent Events, NDJSON, log
streams), use `DefaultNetworkClient.stream(_:)` together with a
`StreamingAPIDefinition`. To cancel every in-flight request and stream
(for example, on logout or backgrounding), call
`DefaultNetworkClient.cancelAll()`. See the draft
[5.0 release notes](docs/releases/5.0.0.md) for preview details and the draft
[5.0 migration guide](docs/Migration-5.0.0.md) for source changes being
prepared. Neither document announces a tagged release.

## Benchmarks

The repository includes a dedicated benchmark runner for quick local comparisons.

```bash
swift run -c release InnoNetworkBenchmarks --quick
swift run -c release InnoNetworkBenchmarks --json-path /tmp/innonetwork-bench.json
```

Benchmark governance, baseline policy, and CI posture are documented in [Benchmarks/README.md](Benchmarks/README.md).

Current guarded quick-baseline highlights from
[`Benchmarks/Baselines/default.json`](Benchmarks/Baselines/default.json)
(`generatedAt`: `2026-07-14T17:50:26Z`):

| Area | Guarded benchmark | Iterations | Baseline ops/sec |
| --- | --- | ---: | ---: |
| Request pipeline | `client/request-pipeline` | 2,000 | 8,058 |
| Request coalescing | `client/request-coalescing-shared-get` | 2,000 | 8,844 |
| Cache lookup | `cache/response-cache-lookup` | 200,000 | 3,051,671 |
| Cache revalidation | `cache/response-cache-revalidation` | 200,000 | 4,559,491 |
| Event fan-out | `events/task-event-fanout-single` | 2,000 | 48,157 |
| Download restore | `persistence/download-persistence-restore` | 50 | 380 |
| WebSocket close classification | `websocket/websocket-close-disposition-classify` | 500,000 | 75,500,668 |

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

- **Foreground is the secure default.** `DownloadConfiguration.safeDefaults`
  and `advanced` permit per-hop redirect admission. Call
  `backgroundTransfersEnabled()` only when the product requires transfers to
  continue outside the app process and accepts Foundation-managed redirects.
- **Background download Info.plist.** A background `URLSession` download does
  not itself require `UIBackgroundModes`. Declare a mode only for a separate
  wake-up mechanism owned by the app, such as `remote-notification`.
- **Session identifier uniqueness.** Each `DownloadConfiguration.sessionIdentifier` must be
  unique among live managers in the app process. The library rejects reuse with
  `DownloadManagerError.duplicateSessionIdentifier`; for background sessions,
  the identifier is also the Foundation background-session identifier. App
  Groups do not make concurrent app/extension ownership safe: coordinate so
  exactly one process owns a given identifier at a time.
- **Destination ownership.** Assign one active logical download to each final
  file path. Different sessions or processes are not serialized merely because
  they share an App Group container.
- **Background completion handler.** Wire the system-provided completion handler (delivered to
  `application(_:handleEventsForBackgroundURLSession:completionHandler:)`) into
  `DownloadManager` so the OS releases the app suspension promptly. The handler
  is paired only with a `urlSessionDidFinishEvents` that occurs after that batch
  is registered; an earlier unscoped finish is never carried forward.

### Observability & Privacy

- **Redaction defaults.** `NetworkEvent` never carries headers or bodies. Before any observer
  receives an event, URL user-info and fragments are removed, query values are redacted, and
  JWT-like path values are masked; failures use stable payload-free categories. The secure
  `NetworkLogger` additionally redacts every header value, cookie, body, query value, and
  free-form error description. `NetworkLoggingOptions.verbose` is an explicit local-debugging
  opt-in and must not be used in CI, shared logs, or production.
- **cURL export.** `URLRequest.curlCommand()` omits request bodies and redacts every header and
  query value by default. `includesHeaderValues`, `includesQueryValues`, and `includesBody` are
  independent explicit opt-ins for a controlled local diagnostic path. URL user-info and
  fragments are never exported.
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
  own `401` refresh + replay. Keep tenant headers, request IDs, and other
  unsigned metadata in `RequestInterceptor`s; use `RequestSigner` for
  body-dependent signatures that must be recomputed after refresh.

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
- Draft 5.0 Migration Guide: [docs/Migration-5.0.0.md](docs/Migration-5.0.0.md)
- Alamofire Migration Cookbook: [docs/MigrationFromAlamofire.md](docs/MigrationFromAlamofire.md)
- Moya Migration Cookbook: [docs/MigrationFromMoya.md](docs/MigrationFromMoya.md)
- DocC Deployment: [docs/DocC_Deployment.md](docs/DocC_Deployment.md)
- Query Encoding Reference: [docs/QueryEncoding.md](docs/QueryEncoding.md)
- WebSocket Lifecycle: [docs/WebSocketLifecycle.md](docs/WebSocketLifecycle.md)
- Task Ownership: [docs/TaskOwnership.md](docs/TaskOwnership.md)
- Draft 5.0 Release Notes: [docs/releases/5.0.0.md](docs/releases/5.0.0.md)
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
