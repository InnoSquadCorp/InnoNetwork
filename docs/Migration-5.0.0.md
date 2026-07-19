# Migration Guide: 5.0.0

This guide describes the unreleased 5.0 draft. There is no `5.0.0` tag yet.

InnoNetwork 5.0 makes endpoint authentication, request identity, signing,
transport admission, and configuration composition explicit. The changes
below intentionally remove 4.x migration bridges that could make the bytes
sent on the wire differ from the request or security policy a caller declared.

## Required source changes

| 4.x usage | 5.0 replacement |
| --- | --- |
| Treating `stream(_:)` as `AsyncThrowingStream<Output, Error>` and casting failures to `NetworkError` | Iterate the returned `StreamingOutputSequence`; a plain `catch` binds `NetworkError` directly |
| Depending on `stream(_:)` to read ahead into an unbounded output queue | Accept the default lossless backpressure, or pass `.unbounded` explicitly after reviewing the memory trade-off |
| `AuthScope`, `PublicAuthScope`, `AuthRequiredScope` | `SessionAuthentication` with `.anonymous`, `.optional`, or `.required` |
| `typealias Auth = PublicAuthScope` | `var sessionAuthentication: SessionAuthentication { .anonymous }` |
| `typealias Auth = AuthRequiredScope` | `var sessionAuthentication: SessionAuthentication { .required }` |
| Implicit public auth on a manual buffered, multipart, or streaming endpoint | Add an explicit `sessionAuthentication` witness |
| `EndpointBuilder<Response, PublicAuthScope>` | `EndpointBuilder<Response>` with `.authentication(.anonymous)` when the default is not already clear at the construction boundary |
| `EndpointBuilder<Response, AuthRequiredScope>` | `EndpointBuilder<Response>` with `.authentication(.required)` |
| `APIAuthentication.public` / macro `auth: .public` | `SessionAuthentication.anonymous` / macro `auth: .anonymous` |
| Closed `enum HTTPMethod` and exhaustive switches | Validated `struct HTTPMethod`; compare standard constants or `rawValue`, and handle custom methods explicitly |
| `RequestExecutionNext.execute(request)` | `RequestExecutionNext.execute()` |
| `.with(retry:)`, `.with(circuitBreaker:)`, `.with(coalescing:)`, `.with(executionPolicies:)` | `ResiliencePack` passed to `NetworkConfiguration.advanced(...)` |
| `.with(refresh:)` | `AuthPack(refreshToken:)` |
| `.with(eventObservers:)` | `ObservabilityPack(eventObservers:)` |
| `.with(cache:)` | `CachePack(responseCache:)` |
| `NetworkConfiguration.recommendedForProduction(baseURL:)` | Start with `safeDefaults(baseURL:)`; add only server-approved policies through `advanced(...)` |
| Mutating a configuration-pack property after initialization | Construct a new immutable pack with the desired named initializer arguments |
| Reading Core, Download, or WebSocket configuration runtime fields | Keep an application-owned input model when inspection is required; build the opaque configuration command through `safeDefaults` or named packs passed to `advanced(...)` |
| `NoOpNetworkLogger()` in a generated executable | Omit the logger witness to inherit the SPI default, or define a private no-op logger in the adapter |
| `DefaultNetworkClient(configuration: .safeDefaults(baseURL: url))` | `DefaultNetworkClient(baseURL: url)` when no custom policy is needed (optional simplification) |
| Public `StateReducer` / `StateReduction` | An application-owned reducer type, or a feature-local reducer |
| Body signing in `RequestInterceptor` | `RequestSigner.signatureHeaders(for:body:)` |
| `await manager.retry(task)` while continuing to use `task` | Capture `WebSocketRetryResult?`, use its fresh `task`, and consume its pre-registered `events` stream |
| `await handshakeAdapter.adapt(request)` | `try await handshakeAdapter.adapt(request)`; adapter closures may throw |
| `WebSocketManager.handleBackgroundSessionCompletion(_:completion:)` | Remove the call; route download identifiers to `DownloadManager`, otherwise invoke the app callback directly |
| `WebSocketConfiguration.sessionIdentifier` / `AdvancedBuilder.sessionIdentifier` | Remove the value; WebSocket sessions are foreground-only and the identifier was never applied |
| `DownloadConfiguration.default` / `WebSocketConfiguration.default` | Call the matching `safeDefaults()` factory; zero-argument manager initialization remains available |
| `DownloadManager.make(configuration:)` | Call the throwing `DownloadManager(configuration:)` initializer |
| Constructing `PersistentResponseCacheStatistics` directly | Read the cache-owned snapshot from `await cache.statistics()`; use an application-owned fixture type for isolated presentation tests |
| Constructing `CircuitBreakerOpenError` directly | Inspect the `SendableUnderlyingError` carried by `NetworkError.underlying`; custom policies should return their own error type |
| Direct `WebSocketConfiguration(...)` initialization | Use `safeDefaults()` or pass immutable thematic packs to `advanced(...)` |
| Constructing a `WebSocketTask` directly | Obtain the handle from `await manager.connect(url:subprotocols:)` or an accepted `retry(_:)` result |
| `import InnoNetworkCodegen` | Remove it; the attached macro ships from `import InnoNetwork` |
| `@APIDefinition(method:path:)` | Add mandatory `auth: .anonymous`, `.optional`, or `.required` |
| `#endpoint(method, path, as: Response.self)` | Use a named macro-assisted endpoint struct or runtime `EndpointBuilder` |
| `client.request(path, method:tag:)` | Use a named `APIDefinition` or an explicit `EndpointBuilder` |
| Passing an optional directly to `EndpointPathEncoding.percentEncodedSegment` | Unwrap it and define the nil behavior before encoding |
| `NetworkConfiguration.responseBodyLimit` | Configure `ResiliencePack(bodyBuffering:)` with `.streaming(maxBytes:)` or `.buffered(maxBytes:)` |
| Assuming `safeDefaults` / `advanced` has an unbounded collected response, including for file uploads | Accept the 5 MiB default, configure another explicit bound, or deliberately select `.streaming(maxBytes: nil)` / `.buffered(maxBytes: nil)` |
| Using `MockURLSession` or VCR replay mode with `safeDefaults` | No configuration change is required; fixture data is buffered by design and the response ceiling is enforced before the response pipeline |
| Using VCR record mode with bounded streaming | Select an explicitly reviewed `.buffered(maxBytes:)` recording profile; record mode forwards to a backing session and fails closed under bounded streaming |
| Plain HTTP downloads, OpenAPI base URLs, or plain WS sockets without an opt-in | Use HTTPS/WSS, or enable the matching scoped `allowsInsecureHTTP` / `allowsInsecureWebSocket` configuration only for an intentional environment |
| Relying on a download preset to create a background session | Keep the secure foreground default, or call `backgroundTransfersEnabled()` after reviewing its redirect trade-off |
| Constructing a `DownloadTask` directly | Start it through `DownloadManager.download(...)` and retain the returned manager-owned handle |
| `addEventListener(for:listener:)`, `removeEventListener(_:)`, and task subscription tokens | Iterate the task-scoped `events(for:)` `AsyncStream`; manager-wide callback setters remain available for integrations that cannot own a stream task |
| `DownloadState.nextStates` / `canTransition(to:)` or `WebSocketState.nextStates` / `canTransition(to:)` | Observe the state value and `isTerminal`; lifecycle transitions are manager-owned invariants |
| `NoOpNetworkEventObserver` / `NoOpEventPipelineMetricsReporter` | Omit the observer from the collection or leave the optional metrics reporter unset |
| `OpenAPIRestOperation` without auth metadata | Add `var sessionAuthentication: SessionAuthentication` and review generated `.anonymous` witnesses against the service security scheme |

## Replace type-level auth scopes with one explicit value

The 4.x phantom types split public and auth-required endpoints at the generic
type level. They could not express "use a session token when available but
still allow an anonymous request," and manual endpoint protocols could inherit
public access silently. In 5.0 every endpoint shape carries the same runtime
value:

- `.anonymous` never invokes the configured `RefreshTokenPolicy`;
- `.optional` applies a current token and refresh replay when a policy exists,
  but permits an anonymous request when it does not; and
- `.required` requires a refresh-token policy and obtains a token before the
  first transport attempt. A missing policy or token acquisition failure is
  surfaced without sending an anonymous request.

Request interceptors and request signers remain explicit, orthogonal
capabilities. InnoNetwork does not infer session authentication from an
`Authorization` header, an arbitrary interceptor, or a signature.

Replace associated-type witnesses on every manual `APIDefinition`,
`MultipartAPIDefinition`, and `StreamingAPIDefinition`:

```swift
// 4.x
struct GetProfile: APIDefinition {
    typealias APIResponse = Profile
    typealias Auth = AuthRequiredScope

    var method: HTTPMethod { .get }
    var path: String { "/profile" }
}

// 5.0
struct GetProfile: APIDefinition {
    typealias APIResponse = Profile

    var method: HTTPMethod { .get }
    var path: String { "/profile" }
    var sessionAuthentication: SessionAuthentication { .required }
}
```

An endpoint that previously relied on the implicit `PublicAuthScope` must now
say `.anonymous`. Use `.optional` only when anonymous and bearer-authenticated
requests are both valid server contracts; it is not a fallback for an endpoint
that must never cross transport without a token.

Remove the auth scope generic from builders:

```swift
// 4.x
let endpoint = EndpointBuilder<EmptyResponse, AuthRequiredScope>
    .get("/profile")
    .decoding(Profile.self)

// 5.0
let endpoint = EndpointBuilder<EmptyResponse>
    .get("/profile")
    .authentication(.required)
    .decoding(Profile.self)
```

The non-generic builder initializer also accepts
`authentication: SessionAuthentication`; its default is `.anonymous`.

## Replace raw-string requests with an explicit endpoint contract

The 4.x `NetworkClient.request(_:method:tag:)` overload inferred only the
decoded response type. It silently selected anonymous session authentication
and method-derived transport defaults, so the call site could not show the
complete security and payload contract. The overload is removed in 5.0.

Prefer a named endpoint for application API catalogs. The struct remains the
source of truth while the macro derives repetitive witnesses:

```swift
// 4.x
let user: User = try await client.request("/users/\(id)")

// 5.0
@APIDefinition(method: .get, path: "/users/{id}", auth: .required)
struct GetUser {
    typealias APIResponse = User
    let id: Int
}

let user = try await client.request(GetUser(id: id))
```

For a genuinely one-off or runtime-composed request, keep the choices visible
with `EndpointBuilder`:

```swift
let user = try await client.request(
    EndpointBuilder<EmptyResponse>
        .get("/users/\(id)")
        .authentication(.required)
        .decoding(User.self)
)
```

## Depend on request and upload capabilities separately

`NetworkClient` now describes only ordinary `APIDefinition` requests.
Multipart execution moved to `UploadNetworkClient`, so request-only wrappers
and test doubles no longer implement upload methods they cannot meaningfully
support. `DefaultNetworkClient` and `StubNetworkClient` conform to both, so
calls made on those concrete types do not change.

Update only existential and generic boundaries that invoke `upload`:

```swift
// 4.x
struct AvatarService {
    let client: any NetworkClient
}

// 5.0 — this service only uploads
struct AvatarService {
    let client: any UploadNetworkClient
}

// Require the composition only when the same dependency performs both.
struct ProfileService {
    let client: any NetworkClient & UploadNetworkClient
}
```

Custom conformers implement the tag-aware primitive for their capability. The
untagged overload forwards `tag: nil` by default, preserving the grouped
cancellation contract without duplicate boilerplate.

## Construct concurrency limiting through its policy

The raw `ConcurrencyTokenBucket` actor is no longer public. It was easy to
acquire in a request interceptor and accidentally skip release when a
transport failure prevented the response interceptor from running. The
execution policy owns both sides of that lifecycle.

```swift
// 4.x
let bucket = ConcurrencyTokenBucket(maxConcurrent: 4)
let limit = ConcurrencyLimitExecutionPolicy(bucket: bucket)

// 5.0
let limit = ConcurrencyLimitExecutionPolicy(maxConcurrent: 4)
```

Register `limit` in `ResiliencePack.customExecutionPolicies`. Reuse the same
policy value in multiple configurations when those clients should share the
cap; construct separate values for independent limits.

## Treat HTTP methods as an open token set

`HTTPMethod` is no longer an enum that can be switched exhaustively. It is a
`RawRepresentable`, `Sendable`, `Hashable` struct with standard constants for
GET, HEAD, POST, PUT, PATCH, DELETE, CONNECT, OPTIONS, and TRACE. Replace
exhaustive switches with equality or a raw-value switch that has a fallback:

```swift
// 4.x — exhaustive because HTTPMethod was a closed enum
switch method {
case .get: routeQuery()
case .post, .put, .patch, .delete: routeBody()
}

// 5.0 — extension methods must reach an explicit fallback
switch method.rawValue {
case HTTPMethod.get.rawValue, HTTPMethod.head.rawValue:
    routeQuery()
case HTTPMethod.post.rawValue, HTTPMethod.put.rawValue,
    HTTPMethod.patch.rawValue, HTTPMethod.delete.rawValue:
    routeBody()
default:
    routeAccordingToApplicationContract(method)
}
```

Create a custom extension method only from a valid RFC 9110 token and handle
the failable initializer:

<!-- compile-check -->
```swift
import InnoNetwork

enum ConfigurationError: Error {
    case invalidHTTPMethod
}

func makePurgeMethod() throws -> HTTPMethod {
    guard let purge = HTTPMethod(rawValue: "PURGE") else {
        throw ConfigurationError.invalidHTTPMethod
    }
    return purge
}
```

Whitespace, controls, non-ASCII values, separators, and an empty token are
rejected. Method equality and all retry, redirect, cache, coalescing, and curl
policy matching remain case-sensitive. Foundation rewrites a few differently
cased standard spellings (for example `get` to `GET`) when they are assigned to
`URLRequest`; InnoNetwork now fails those requests before transport instead of
silently changing the wire method. Use the uppercase standard constant when
that standard method is intended.

GET and HEAD now default to query transport. Request building rejects encoded
bodies for GET, HEAD, and TRACE before any network I/O. The macro infers a
stored `query` only for GET/HEAD and a stored `body` only for
POST/PUT/PATCH/DELETE. For OPTIONS, CONNECT, TRACE, custom, or dynamic methods,
declare a complete `Parameter` + `parameters` pair and choose `transport`
explicitly instead of relying on simple macro inference.

## Request execution policies preserve request identity

`RequestExecutionNext.execute(_:)` is replaced by the zero-argument
`RequestExecutionNext.execute()`. A policy can still short-circuit by calling
`next` zero times or replay the same transport request by calling it multiple
times, but it cannot substitute another `URLRequest`.

Move URL, header, and body adaptation into a `RequestInterceptor`:

```swift
struct HeaderInterceptor: RequestInterceptor {
    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue("example", forHTTPHeaderField: "X-Example")
        return request
    }
}

struct TracingPolicy: RequestExecutionPolicy {
    func execute(
        input: RequestExecutionInput,
        context: RequestExecutionContext,
        next: RequestExecutionNext
    ) async throws -> Response {
        recordStart(request: input.request, context: context)
        let response = try await next.execute()
        recordFinish(response: response, context: context)
        return response
    }
}
```

This keeps cache, coalescing, retry, signing, and transport identity aligned
around the executor-owned request.

## Compose configuration with packs

The seven deprecated `NetworkConfiguration.with(...)` modifiers are removed.
Construct the complete policy set at one call site:

```swift
let configuration = NetworkConfiguration.advanced(
    baseURL: baseURL,
    resilience: ResiliencePack(
        retry: ExponentialBackoffRetryPolicy(maxRetries: 2),
        coalescing: .getOnly,
        circuitBreaker: CircuitBreakerPolicy(failureThreshold: 5),
        customExecutionPolicies: [reachabilityPolicy]
    ),
    auth: AuthPack(refreshToken: refreshPolicy),
    observability: ObservabilityPack(eventObservers: [observer]),
    cache: CachePack(responseCache: cache)
)
```

Pack fields default to `nil`, so specify only the axes the client owns. To
disable a policy that a preset enables, construct an explicit advanced
configuration instead of mutating that preset after construction.

## Own reducer vocabulary at the feature boundary

`StateReducer` and `StateReduction` are no longer public API. They only
described package lifecycle mechanics and did not provide transport behavior.
Applications that used the generic names should define a small local protocol
or return a feature-specific tuple/value from their reducer. There is no
runtime migration and no replacement module to import.

## Sign the final body, not a preliminary request

Body-aware authentication moves to `RequestSigner`. In 5.0 the executor:

1. encodes the payload and snapshots caller-owned files;
2. runs configuration and endpoint request interceptors;
3. applies the current refresh token;
4. runs configuration signers, then endpoint signers; and
5. sends the exact `RequestBody` observed by the signers.

Signing runs for every retry and refresh replay. HMAC, request-minted JWT, and
AWS SigV4 reference implementations now conform to `RequestSigner` despite
their legacy `Interceptor` suffixes. Opaque `httpBodyStream` values are
rejected; use data or explicit file payloads.

Signed requests bypass response-cache reads and writes, request coalescing,
and URLSession caching. They also reject every automatic redirect because a
URLSession-generated follow-up cannot pass through the asynchronous signer.
Issue a new typed request after validating an intentional redirect target.

See the [Request Signing guide](../Sources/InnoNetwork/InnoNetwork.docc/Articles/RequestSigning.md)
for custom signer and file-lifetime examples.

## Obtain WebSocket tasks from their manager

`WebSocketTask` construction is package-owned in 5.0. A caller-created task
had no public operation that could register it with a manager or move it out
of its initial state, so it could not represent a live connection. Start the
connection through its owner instead:

```swift
// 4.x
let task = WebSocketTask(url: socketURL, subprotocols: ["chat.v1"])

// 5.0
let task = await manager.connect(
    url: socketURL,
    subprotocols: ["chat.v1"]
)
```

The returned handle remains the source of task identity, lifecycle state,
events, counters, and explicit retry. Do not synthesize task IDs for
restoration; create a new manager-owned connection and retain the returned
handle.

## WebSocket explicit retry creates a fresh task

In 5.0, `WebSocketManager.retry(_:)` returns `WebSocketRetryResult?`. An
accepted explicit retry retires the terminal source handle and creates a new
logical task with a fresh UUID-backed `id`. The result also carries a bounded
event stream that is registered before the replacement transport resumes. The
source task remains terminal and its listeners and `AsyncStream` consumers
finish on the old identity, so retaining the old handle no longer follows the
replacement connection.

Capture the replacement and register task-scoped consumers again:

```swift
var currentTask = await manager.connect(url: socketURL)
var currentEvents = await manager.events(for: currentTask)

while true {
    for await event in currentEvents {
        print(event)
    }

    guard
        case .peerApplicationFailure(.custom(4001), _) =
            await currentTask.closeDisposition
    else { break }

    await refreshApplicationState()
    guard let retryResult = await manager.retry(currentTask) else { break }
    currentTask = retryResult.task
    currentEvents = retryResult.events
}
```

Automatic reconnect is intentionally unchanged: the public task and `id` stay
the same, task-scoped consumers remain attached, and only the underlying
`URLSessionWebSocketTask` changes between transport generations.

An explicit retry is accepted once for a terminal source task and only by its
owning manager. It returns `nil` when the source is nonterminal, was already
claimed, belongs to another manager, or shutdown admission is closed. A retry
that was admitted just before shutdown may return a non-`nil` result whose task
is already terminal with the manager-shutdown connection error; consume the
returned stream rather than attempting a second registration after the race.

## Catch typed WebSocket messaging errors

`WebSocketManager.send(_:message:)`, `send(_:string:)`, and `ping(_:)` throw
`WebSocketError` as a typed error in 5.0. A plain `catch` block now binds
`WebSocketError` directly, so `catch let error as WebSocketError` casts are
redundant. Two behavioral changes ride along: raw transport errors no longer
escape `send` unmapped (they arrive as `WebSocketError.connectionFailed` or
`.cancelled`), and a send or ping rejected because the task lifecycle gate is
shutting down throws `WebSocketError.cancelled` instead of Swift's
`CancellationError`.

```swift
// 4.x
do {
    try await manager.send(task, string: "hello")
} catch let error as WebSocketError {
    handle(error)
} catch {
    // raw URLError could land here
}

// 5.0
do {
    try await manager.send(task, string: "hello")
} catch {
    handle(error)  // error is WebSocketError
}
```

## Allow WebSocket handshake adaptation to fail

`WebSocketHandshakeRequestAdapter` now stores an `async throws` closure and
its public `adapt(_:)` method is `async throws`. Existing nonthrowing closures
continue to fit the initializer, but direct calls must add `try`:

```swift
let adapter = WebSocketHandshakeRequestAdapter { request in
    var request = request
    let token = try await tokenStore.validToken()
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return request
}

let adapted = try await adapter.adapt(request)
```

When a configured adapter throws, the manager surfaces the error through the
task's normal connection-failure lifecycle. It may participate in automatic
reconnect within the configured budget. If disconnect, shutdown, or a newer
generation wins while the adapter is suspended, the stale result or failure is
discarded. The adapted URL is admitted again before `URLSessionWebSocketTask`
creation, so an adapter cannot silently replace WSS with disallowed WS or add
userinfo, a fragment, or path traversal.

## Remove WebSocket background-session compatibility no-ops

`WebSocketManager.handleBackgroundSessionCompletion(_:completion:)` is
removed. WebSocket tasks run in foreground/default sessions and cannot resume
through Foundation's background-transfer callback. The 4.x method ignored the
identifier and invoked the completion immediately, which made it look like the
manager owned lifecycle work that it did not perform.

`WebSocketConfiguration.sessionIdentifier` and
`AdvancedBuilder.sessionIdentifier` are removed for the same reason. The
identifier was stored but never applied to the foreground
`URLSessionConfiguration.default`, so changing it provided no session
isolation, restoration, or runtime behavior.

Continue forwarding real background download identifiers to
`DownloadManager.handleBackgroundSessionCompletion(_:completion:)`. If an
application router receives an identifier that belongs to no background
transfer owner, invoke the app-provided completion directly according to that
router's policy.

## Replace configuration `default` aliases

`DownloadConfiguration.default` and `WebSocketConfiguration.default` are
removed because both were exact aliases for the more explicit
`safeDefaults()` factories. Replace only call sites that pass or retain a
configuration value:

```swift
// 4.x
let downloadConfiguration = DownloadConfiguration.default
let socketConfiguration = WebSocketConfiguration.default

// 5.0
let downloadConfiguration = DownloadConfiguration.safeDefaults()
let socketConfiguration = WebSocketConfiguration.safeDefaults()
```

Zero-argument construction remains available. `try DownloadManager()` and
`WebSocketManager()` still select their secure presets without requiring a
configuration argument.

## Use the DownloadManager initializer

`DownloadManager.make(configuration:)` was an exact forwarding alias for the
public throwing initializer, including the same default configuration and
errors. In 5.0 the initializer is the single construction path:

```swift
// 4.x
let manager = try DownloadManager.make(configuration: configuration)

// 5.0
let manager = try DownloadManager(configuration: configuration)
```

This changes only the spelling. Ownership, restoration, duplicate-session
validation, and shutdown behavior remain unchanged.

## Read persistent cache statistics from the cache

`PersistentResponseCacheStatistics` follows the same ownership rule as the
event-pipeline metric snapshots in 5.0: its properties remain public, but only
the owning cache actor constructs it. Replace direct initialization with
`await cache.statistics()`. Presentation or dashboard tests that do not own a
cache should use an application fixture rather than synthesizing a library
runtime snapshot.

`CircuitBreakerOpenError` follows the same producer-owned rule. The built-in
breaker converts it to `SendableUnderlyingError` before surfacing
`NetworkError.underlying`, so callers should inspect that wrapper's `domain`,
`code`, and message. Custom execution policies should define and throw their
own domain-specific error instead of synthesizing a built-in breaker result.

## Tune WebSocket configuration through presets

The direct 21-parameter `WebSocketConfiguration` initializer is also
package-owned in 5.0. Move explicit tuning into the thematic advanced packs:

```swift
// 4.x
let configuration = WebSocketConfiguration(
    heartbeatInterval: 10,
    maxReconnectAttempts: 2
)

// 5.0
let configuration = WebSocketConfiguration.advanced(
    liveness: WebSocketLivenessPack(heartbeatInterval: 10),
    reconnect: WebSocketReconnectPack(maxAttempts: 2)
)
```

`advanced(...)` retains its documented advanced-tuning seed. Each immutable
pack exposes one initializer for its cohesive policy area; omitted arguments
retain that area's advanced defaults.

## Redirect defaults are stricter

The default redirect policy now denies HTTPS-to-HTTP downgrade, strips every
caller-prepared original header plus built-in and configured sensitive session
headers when authority changes, and denies any cross-origin redirect that
retains an unsafe method. Signed requests deny automatic redirects even when
the target is same-origin.

For core URLSession-backed requests, every header value configured through
`URLSessionConfiguration.httpAdditionalHeaders` is now explicitly cleared on
cross-origin redirect hops. Foundation otherwise restores a removed session
default after the redirect callback returns. Same-origin redirects continue to
receive those configured values. If a target origin needs a credential, issue
a separate validated request with credentials scoped to that origin.

If an API contract requires a redirect that the defaults reject, treat the 3xx
as application data, validate the target explicitly, and start a new typed
request. Do not forward authorization, cookie, proxy authorization, API-key,
or signature headers across authority boundaries.

## Use the matching secure-transport opt-in

URL admission is shared by the core client, streaming requests, downloads,
WebSockets, and `InnoNetworkClientTransport`. The admitted URL must have the
expected HTTP or WebSocket scheme, a nonempty unambiguous host, no userinfo or
fragment, and no raw or recursively percent-encoded `.` / `..` path segment.
OpenAPI request targets must remain relative and cannot replace the configured
origin.

Use HTTPS and WSS in production. When a loopback, LAN, or staging environment
intentionally uses a plain scheme, enable only its matching configuration:

```swift
let localClientConfiguration = NetworkConfiguration.advanced(
    baseURL: URL(string: "http://localhost:8080")!,
    transport: TransportPack(allowsInsecureHTTP: true)
)

let localDownloadConfiguration = DownloadConfiguration.advanced(
    transfer: DownloadTransferPack(allowsInsecureHTTP: true)
)

let localSocketConfiguration = WebSocketConfiguration.advanced(
    connection: WebSocketConnectionPack(allowsInsecureWebSocket: true)
)

let localGeneratedClientTransport = InnoNetworkClientTransport(
    session: session,
    allowsInsecureHTTP: true
)
```

These flags permit only HTTP or WS on that configuration. They do not bypass
host, userinfo, fragment, origin-override, or traversal checks. If an existing
route intentionally contains a literal dot segment, change the server route or
request contract; there is no traversal-admission opt-out.

WebSocket handshake redirects now repeat URL admission on every hop. A secure
WSS connection never downgrades to WS, even when the configuration permits an
intentional plain-WS starting URL. Cross-origin redirects strip credential
headers and arbitrary caller-prepared header names, while preserving the
required WebSocket handshake and subprotocol negotiation fields. Credential
decisions remain bound to the original handshake origin across multiple hops.
A rejected target becomes a terminal `.invalidURL` failure and does not consume
the reconnect budget.

The safe and advanced download presets now use a foreground session.
Foreground downloads apply `DefaultRedirectPolicy` and URL admission before
following every redirect.
HTTPS downgrade, unsafe cross-origin method replay, missing retained origin
metadata, and traversal targets terminate as `DownloadError.invalidURL`
without retry. `DownloadTransferPack(allowsInsecureHTTP: true)` permits an
intentional plain-HTTP source and same-scheme foreground redirect; it does not
enable an HTTPS downgrade through the foreground redirect policy.

If an existing app depends on process-independent transfers, opt back into a
background session explicitly:

```swift
let backgroundDownloads = DownloadConfiguration.advanced(
    sessionIdentifier: "com.example.app.downloads",
    transfer: DownloadTransferPack(maxConnectionsPerHost: 4)
).backgroundTransfersEnabled()
```

Use a conventional reverse-DNS session identifier. It is still passed to
Foundation unchanged, but persistence and completion staging now map any
path-like, uppercase, oversized, empty, or non-ASCII identifier to one
deterministic SHA-256 directory component. Conventional lowercase ASCII
reverse-DNS identifiers retain their existing directory. If a preview build
used values such as `../downloads`, `a/b`, or `com.Example.downloads`, audit the
configured persistence base and migrate or remove the legacy out-of-root,
nested, or case-aliased artifacts before rollout.

This is a security/continuation trade-off. Foundation background sessions
follow redirects automatically without invoking the redirect delegate, so
InnoNetwork cannot run per-hop redirect policy or URL-admission preflight in
that mode. Initial URLs and final URLs exposed at library lifecycle boundaries
remain validated where applicable, but final validation cannot undo contact
with an intermediate redirect target. Keep the foreground default unless
continuing outside the app process is a product requirement.

`DownloadTask` construction is now package-owned. A task handle represents
manager registration, persistence, callback correlation, and URLSession
ownership; a caller-created actor could never establish those invariants. Use
`DownloadManager.download(...)` and retain the returned handle for pause,
resume, retry, cancellation, and event observation.

The direct 22-parameter `DownloadConfiguration` initializer is package-owned
in 5.0. Replace it with `safeDefaults(sessionIdentifier:)` for conservative
defaults or `advanced(sessionIdentifier:_:)` for explicit tuning. This also
removes the former ambiguity where `DownloadConfiguration()` enabled cellular
access while `safeDefaults()` and `.default` did not.

Download restoration and shutdown now form a strict lifecycle boundary:

- restored and opaque resume tasks are adopted only when both retained request
  URLs match the persisted admitted source;
- shutdown cancels and joins restoration, drains mutations admitted before the
  shutdown latch, removes their persistence records, and prevents a suspended
  operation from resuming a URL task after teardown begins;
- progress delegate callbacks are coalesced per URL-task segment, while
  completions remain lossless and ordered; and
- app-facing callbacks are delivered in per-task order outside the system
  delegate FIFO, so slow progress and terminal handlers do not delay the
  background-session completion handler; pre-transport waiting/downloading
  handlers remain admission hooks; and
- completed, failed, and cancelled events atomically seal their bounded task
  partition. A manager callback may call `shutdown()`; that reentrant call
  starts teardown and returns so it cannot wait on its own restoration or
  delegate worker. A later external `shutdown()` still waits for full teardown.

Background restoration now closes its one-shot completion window at
`urlSessionDidFinishEvents(forBackgroundURLSession:)`, not at the earlier
`allDownloadTasks()` inventory snapshot. Register the UIKit completion handler
through `handleBackgroundSessionCompletion` for each batch; a finish event seen
without a registered handler is not reused by a later batch.

Completion commits now use an attempt-scoped admission gate and a deterministic
journal containing the admitted source/final URLs, destination, byte count, and
payload SHA-256. A `.terminal(.finished)` receipt is removed only by an exact
metadata/outcome acknowledgment after terminal event and callback admission.
If the final destination no longer matches that receipt on restore, the task
fails with `DownloadError.fileSystemError` while the receipt and staged payload
remain available for an explicit recovery policy. Policy-rejected journals are
explicitly abandoned and cleaned so they cannot block manual retry.

App Group storage is not a multi-owner lock. Exactly one process may own a
background session identifier at a time, and callers must give concurrent
logical downloads distinct final destination paths. OS-driven reattachment by
an alternate app/extension process requires both targets to share an App
Group-backed `persistenceBaseDirectoryURL` in addition to Foundation's
`sharedContainerIdentifier`; otherwise the restored system task has no matching
InnoNetwork logical record and is cancelled. `shutdown()` cancels and removes
the current owner's records, so it is not a proactive live-handoff operation.

Apps should continue to treat `shutdown()` as the owner's final operation and
create a fresh manager for later work. Existing event streams now receive one
authoritative terminal outcome before ending, including under saturated
`.dropNewest` or `.dropOldest` delivery policies.

## Choose a response ceiling deliberately

`NetworkConfiguration.responseBodyLimit`, the 4.x compatibility alias for
the active policy's byte ceiling, is removed. Collection mode and limit now
have one source of truth: `responseBodyBufferingPolicy`. Configure it through
`ResiliencePack(bodyBuffering:)` when using `advanced(...)`, and pattern
match the public enum when an application needs to inspect the selected mode
or associated limit.

`NetworkConfiguration.safeDefaults(baseURL:)` and
`NetworkConfiguration.advanced(...)` now use streaming
collection with a 5 MiB maximum for inline requests and file-backed uploads.
This is a behavior change for clients
that previously relied on an unbounded default.

Keep the default for ordinary JSON. For a known larger payload, set a
bounded product-specific ceiling. Reserve `nil` for a deliberate unbounded
decision:

<!-- compile-check -->
```swift
import Foundation
import InnoNetwork

let baseURL = URL(string: "https://api.example.com")!

let bounded = NetworkConfiguration.advanced(
    baseURL: baseURL,
    resilience: ResiliencePack(
        bodyBuffering: .streaming(maxBytes: 20 * 1024 * 1024)
    )
)

let explicitlyUnbounded = NetworkConfiguration.advanced(
    baseURL: baseURL,
    resilience: ResiliencePack(
        bodyBuffering: .streaming(maxBytes: nil)
    )
)
```

`.buffered(maxBytes:)` has the same explicit-`nil` opt-out. The 5.0 enum cases
require the argument, so the former `.streaming()` and `.buffered()` shorthand
no longer compiles; every unbounded choice must spell `maxBytes: nil`.

For inline requests, `.buffered(maxBytes:)` uses `URLSession.data(for:)` and
checks the byte count only after the complete response has been buffered. It
prevents an oversized body from reaching cache storage or decoding, but it is
not an early transport or peak-memory bound. Bounded `.streaming(maxBytes:)`
checks `Content-Length` and observed bytes while receiving the body, explicitly
cancels the underlying task when the ceiling is crossed, and fails closed when
a custom session cannot provide streaming bytes.

`MockURLSession` and VCR replay mode are the intentional test-only exception.
Their scripted fixture or cassette body is already buffered, so they use
`data(for:)` with bounded presets and the executor checks the same ceiling
before cache insertion, interceptors, or decoding. VCR record mode forwards to
a backing session and fails closed under bounded streaming; use a deliberately
configured `.buffered(maxBytes:)` profile while recording. This preserves
ordinary consumer tests without making buffered fallback a public capability
or silently weakening production custom sessions.

File-backed uploads choose their Foundation task shape from the presence of a
response bound, regardless of whether the policy case is `.streaming` or
`.buffered`: a non-`nil` bound uses a streamed data task, supplies the file as
an `httpBodyStream`, and sets an explicit `Content-Length` so the response can
be cancelled early. An explicit `maxBytes: nil` preserves
`URLSession.upload(for:fromFile:)`. The bounded file-upload capability is
package-only, so an external custom `URLSessionProtocol` fails closed for a
bounded file upload. Use Foundation `URLSession` for bounded uploads, or select
an explicit unbounded policy only when that behavior is reviewed.

## Move macro definitions to the root package

The 4.x nested `Packages/InnoNetworkCodegen` package and `#endpoint`
expression macro are removed. The root package now enables the attached macro
by default, so remove `import InnoNetworkCodegen` and keep `import InnoNetwork`:

```swift
// 4.x
import InnoNetwork
import InnoNetworkCodegen

@APIDefinition(method: .get, path: "/users/{id}")
struct GetUser {
    typealias APIResponse = User
    let id: Int
}
```

In 5.0, the same explicit endpoint struct compiles from the root product alone:

<!-- compile-check -->
```swift
import InnoNetwork

struct User: Codable, Sendable {}

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
struct GetUser {
    typealias APIResponse = User
    let id: Int
}
```

This is macro-first without making the macro the endpoint abstraction. The
explicit struct remains the source of truth: `APIResponse`, stored request
inputs, and any custom headers, interceptors, transport, decoder, or policy
remain on it. The macro derives conformance, method, percent-encoded path,
`sessionAuthentication`, and the supported simple payload shape. A stored
`query` is inferred only for GET and HEAD; a stored `body` is inferred only for
POST, PUT, PATCH, and DELETE. OPTIONS, CONNECT, TRACE, custom, and dynamic
methods do not receive simple payload inference. Declare the complete
`Parameter` + `parameters` pair and an explicit transport when the endpoint
needs one of those or any other custom payload contract.

Definitions now fail closed when response or auth intent is missing, a path is
unsafe or references an unsupported property, or generated witnesses conflict.
In simple mode, tuple/destructured bindings and any stored property that is not
consumed by a path placeholder or the inferred `query` / `body` payload are
compile errors, so declared request input cannot disappear silently. A complete
`Parameter` + `parameters` pair is the explicit escape hatch for custom
payload modeling and disables simple payload inference.
Optional values are no longer accepted by the public path-segment encoder;
unwrap them and decide whether nil means omit, substitute, or reject before
constructing a path. `@APIDefinition` reports this directly for `T?`,
`Optional<T>`, and `Swift.Optional<T>` properties. A property whose typealias
resolves to Optional now receives the same targeted generated-code diagnostic
instead of an unrelated generic-constraint error.

Consumers that do not use macros can disable the default trait:

```swift
.package(
    url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
    branch: "main",
    traits: []
)
```

`5.0.0` is not published yet, so this branch dependency is a moving preview
and must not be treated as a stable production pin. Replace the branch
requirement with a version-based requirement only after the annotated release
tag is published.

This excludes the macro declaration and compiler plug-in products from the
target graph and compilation. SwiftPM can still resolve or fetch the
manifest-level `swift-syntax` dependency. Traits are unified per package across
the resolved graph, so every dependency path must keep `Macros` disabled for a
core-only build.

## Add OpenAPI auth metadata and honor no-body responses

Every `OpenAPIRestOperation` now has the same explicit auth witness as a manual
endpoint:

```swift
struct ListPetsOperation: OpenAPIRestOperation {
    typealias Response = [Pet]

    var method: HTTPMethod { .get }
    var path: String { "/pets" }
    var sessionAuthentication: SessionAuthentication { .required }
}
```

The bundled `openapi-to-innonetwork` preview generator writes `.anonymous`
because its supported subset does not interpret OpenAPI security schemes.
Regenerate to obtain the required witness, then review each operation and
change the value where the server requires or optionally accepts a session
token. Do not treat generated `.anonymous` as a security decision made from
the OpenAPI document.

`InnoNetworkClientTransport` now returns `nil` for the generated-client
`HTTPBody` on every HEAD response, successful CONNECT `2xx`, and status `1xx`,
`204`, `205`, or `304`. Remove workarounds that attempted to decode
server-supplied bytes for those responses; the HTTP semantics take precedence
over misleading `Content-Length` or payload bytes.

Generated-client transport redirects now use the same fail-closed default
policy and per-hop URL admission as foreground core requests. If an operation
previously depended on an HTTPS downgrade, a cross-origin unsafe-method replay,
or a malformed target, it now throws
`InnoNetworkClientTransportError.redirectRejected`. Treat the original 3xx as
an application contract and issue a new validated request rather than relaxing
the transport boundary.

Cross-origin generated-client redirects no longer forward original request
headers. Values configured through
`URLSessionConfiguration.httpAdditionalHeaders` are explicitly cleared as well,
because Foundation otherwise re-injects a removed value after the redirect
delegate returns.

Pass a default or ephemeral URLSession to `InnoNetworkClientTransport`.
Background URLSession instances now throw
`InnoNetworkClientTransportError.backgroundSessionUnsupported` before request
dispatch because Foundation follows their redirects without invoking the task
redirect delegate.

Keep `swift-http-types` and OpenAPI Runtime models behind the optional
`InnoNetworkOpenAPI` product. The 5.0 migration does not replace core
`HTTPMethod`, `HTTPHeaders`, `Response`, or endpoint contracts with HTTPTypes.

## Expect cache-key and persistent-format reset

`ResponseCacheKey` no longer sorts query items. Query order can affect
signatures, duplicate-key behavior, and application routing, so
`/search?a=1&b=2` and `/search?b=2&a=1` are different cache identities in 5.0.
Review tests or custom invalidation code that assumed reordered queries would
collapse to one entry.

The persistent cache index is version 4. It HMAC-protects the complete raw
query before writing a disk key, while retaining query ordering and duplicate
keys in the digest input. Opening a version-3-or-older or unknown index
cold-resets the index and body store instead of retaining legacy raw query
material. Treat the first 5.0 launch as a cold cache; do not rely on a
persistent response surviving the upgrade. This is cache eviction, not
application-data migration.

## Re-audit diagnostic opt-ins and owned storage

`URLRequest.curlCommand()` is privacy-safe by default in 5.0:

- request bodies are omitted unless `CurlCommandOptions(includesBody: true)`;
- query keys remain visible, but values are redacted unless
  `includesQueryValues: true`;
- header names remain visible, but every value is redacted unless
  `includesHeaderValues: true`; and
- userinfo and fragments are always removed.

Use header/query/body opt-ins only in a controlled local debugging path. They
are not appropriate defaults for production logs. Network event URLs follow
the same query/userinfo/fragment policy, mask JWT-like path values, and publish
stable failure categories instead of potentially sensitive error payload text.
`DefaultNetworkLogger` also redacts every request and response header value by
default rather than trying to identify sensitive custom header names. Its
secure error path logs the same stable failure category used by events.

The 5.0 preview removes `CurlCommandOptions.redactedHeaderNames`,
`CurlCommandOptions.defaultRedactedHeaderNames`, and
`NetworkLoggingOptions.sensitiveHeaderNames`. Replace selective deny-lists with
the fail-closed defaults. A controlled local diagnostic that truly needs raw
header values can opt in with `includesHeaderValues: true` for cURL or
`redactSensitiveData: false` / `NetworkLoggingOptions.verbose` for the logger.

`PersistentResponseCacheConfiguration.dataProtectionClass` now defaults to
`.completeUntilFirstUserAuthentication` instead of `.completeUnlessOpen`.
Cache-owned bodies, index, key, and subdirectories are excluded from backup;
the caller-supplied root is not, because it may contain unrelated app files.
Download-owned task metadata, logs, checkpoints, locks, temporary paths, and
staging directories receive the same backup exclusion on Darwin. Cache- and
download-owned paths additionally receive the configured
`.completeUntilFirstUserAuthentication` Data Protection class on iOS, tvOS,
watchOS, and visionOS; macOS does not apply an iOS-family protection class. The
final downloaded payload and its metadata remain owned by the caller.

If an app intentionally needs another cache protection class, keep passing it
explicitly. `DataProtectionClass.none` remains an explicit request for
unprotected cache-owned files; it does not disable backup exclusion.

## Update local release and consumer gates

Example package deployment targets now match the root package floors: iOS 16,
macOS 14, tvOS 16, watchOS 9, and visionOS 1. Align copied or downstream smoke
manifests so they test the same supported range.

CI and release workflows now require macOS, iOS, tvOS, watchOS, and visionOS
SDKs. tvOS/watchOS/visionOS cross-compile every public library product with the
package's minimum device target triple, so the gate does not depend on a hosted
runner retaining simulator runtimes. A missing SDK or platform compile failure
fails instead of producing an advisory skip. Dependency review is also
blocking; the repository dependency graph must be enabled and
dependency-policy findings must be resolved.

The 5.0 release notes begin with `<!-- release-status: draft -->` while this
migration is under development. Do not tag from a draft. Release publication
requires the exact top-of-file `<!-- release-status: ready -->` marker in
addition to the remaining release checks. The ready marker is not a standalone
switch: README, API stability, CHANGELOG, security support, the public-symbol
baseline, this guide, release-note status, and release date must move to the
released 5.0 state in the same commit. The docs-state validator reads the
tagged Git tree and fails closed on a mixed transition.

## Pre-flight checklist

- [ ] Remove `AuthScope`, `PublicAuthScope`, `AuthRequiredScope`, and
  `APIAuthentication` references; give every manual, macro, streaming,
  multipart, builder, and OpenAPI endpoint an explicit
  `SessionAuthentication` decision.
- [ ] Verify `.required` endpoints have a `RefreshTokenPolicy` and cannot reach
  transport anonymously; use `.optional` only where the server permits both
  authenticated and anonymous requests.
- [ ] Replace exhaustive `HTTPMethod` switches, handle failable custom tokens,
  and audit HEAD/TRACE body usage plus custom-method transport choices.
- [ ] Replace every `next.execute(request)` call with `next.execute()` and
  move adaptation to `RequestInterceptor`.
- [ ] Replace the seven `.with(...)` modifiers with configuration packs.
- [ ] Move adopter-defined `StateReducer` conformances to app-owned types.
- [ ] Move body-dependent authentication to `RequestSigner`.
- [ ] Verify any redirect-dependent endpoint against the stricter policy.
- [ ] Exercise signed data and file uploads, retries, and refresh replays.
- [ ] Capture every `WebSocketManager.retry(_:)` result, consume its returned
  event stream, and attach any additional listeners to its fresh task.
- [ ] Add `try` to direct WebSocket handshake-adapter calls and exercise thrown
  adapter failures across reconnect, disconnect, and shutdown.
- [ ] Keep automatic-reconnect observers on the existing task; do not create a
  second task for a transport-generation change.
- [ ] Remove the nested codegen package/import, add explicit `auth:` to every
  macro endpoint, and replace `#endpoint` call sites.
- [ ] Replace macro `auth: .public` with `.anonymous`; use simple `query`
  inference only for GET/HEAD and simple `body` inference only for
  POST/PUT/PATCH/DELETE.
- [ ] Decide whether each optional path value is omitted, substituted, or
  rejected before segment encoding.
- [ ] Move intentional plain HTTP/WS use behind its matching scoped opt-in and
  remove routes that contain origin overrides, userinfo, fragments, or dot
  traversal.
- [ ] Accept or explicitly replace the new 5 MiB collected-response cap; keep
  unbounded `nil` policies limited to reviewed payloads.
- [ ] Regenerate/review OpenAPI auth witnesses and remove
  HEAD/successful-CONNECT-2xx/1xx/204/205/304 response-body assumptions.
- [ ] Expect a version-3 persistent-cache cold start and update query-order
  cache tests.
- [ ] Review every curl body/query opt-in and any code that assumed
  `.completeUnlessOpen` was the persistent-cache default.
- [ ] If using `traits: []`, verify no other dependency path re-enables the
  default `Macros` trait.
- [ ] Run the required macOS/iOS/tvOS/watchOS/visionOS build matrix and resolve
  blocking dependency-review findings before changing release status to
  `ready`.

## See also

- [API_STABILITY.md](../API_STABILITY.md) for the 5.x compatibility contract.
- [Migration-4.0.0.md](Migration-4.0.0.md) for the original public baseline.
- [MIGRATION_POLICY.md](MIGRATION_POLICY.md) for the general migration policy.
