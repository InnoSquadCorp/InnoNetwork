# Migration Guide: 5.0.0

This guide describes the unreleased 5.0 draft. There is no `5.0.0` tag yet.

InnoNetwork 5.0 makes endpoint authentication, request identity, signing,
transport admission, and configuration composition explicit. The changes
below intentionally remove 4.x migration bridges that could make the bytes
sent on the wire differ from the request or security policy a caller declared.

## Required source changes

| 4.x usage | 5.0 replacement |
| --- | --- |
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
| Public `StateReducer` / `StateReduction` | An application-owned reducer type, or a feature-local reducer |
| Body signing in `RequestInterceptor` | `RequestSigner.signatureHeaders(for:body:)` |
| `await manager.retry(task)` while continuing to use `task` | Capture `WebSocketRetryResult?`, use its fresh `task`, and consume its pre-registered `events` stream |
| `await handshakeAdapter.adapt(request)` | `try await handshakeAdapter.adapt(request)`; adapter closures may throw |
| `import InnoNetworkCodegen` | Remove it; the attached macro ships from `import InnoNetwork` |
| `@APIDefinition(method:path:)` | Add mandatory `auth: .anonymous`, `.optional`, or `.required` |
| `#endpoint(method, path, as: Response.self)` | Use a named macro-assisted endpoint struct or runtime `EndpointBuilder` |
| Passing an optional directly to `EndpointPathEncoding.percentEncodedSegment` | Unwrap it and define the nil behavior before encoding |
| Assuming `safeDefaults` / `advanced` has an unbounded inline response | Accept the 5 MiB default, configure another explicit bound, or deliberately select `.streaming(maxBytes: nil)` / `.buffered(maxBytes: nil)` |
| Plain HTTP downloads, OpenAPI base URLs, or plain WS sockets without an opt-in | Use HTTPS/WSS, or enable the matching scoped `allowsInsecureHTTP` / `allowsInsecureWebSocket` configuration only for an intentional environment |
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

```swift
guard let purge = HTTPMethod(rawValue: "PURGE") else {
    throw ConfigurationError.invalidHTTPMethod
}
```

Whitespace, controls, non-ASCII values, separators, and an empty token are
rejected. Method equality remains case-sensitive because the value sent on the
wire is case-sensitive.

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

## Redirect defaults are stricter

The default redirect policy now denies HTTPS-to-HTTP downgrade, strips the
expanded sensitive-header set when authority changes, and denies cross-origin
`307`/`308` redirects for unsafe methods. Signed requests deny automatic
redirects even when the target is same-origin.

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

let localDownloadConfiguration = DownloadConfiguration.advanced {
    $0.allowsInsecureHTTP = true
}

let localSocketConfiguration = WebSocketConfiguration.advanced {
    $0.allowsInsecureWebSocket = true
}

let localGeneratedClientTransport = InnoNetworkClientTransport(
    session: session,
    allowsInsecureHTTP: true
)
```

These flags permit only HTTP or WS on that configuration. They do not bypass
host, userinfo, fragment, origin-override, or traversal checks. If an existing
route intentionally contains a literal dot segment, change the server route or
request contract; there is no traversal-admission opt-out.

## Choose an inline response ceiling deliberately

`NetworkConfiguration.safeDefaults(baseURL:)`,
`NetworkConfiguration.advanced(...)`, and
`NetworkConfiguration.recommendedForProduction(baseURL:)` now use streaming
inline collection with a 5 MiB maximum. This is a behavior change for clients
that previously relied on an unbounded default.

Keep the default for ordinary JSON. For a known larger inline payload, set a
bounded product-specific ceiling. Reserve `nil` for a deliberate unbounded
decision:

```swift
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

`.buffered(maxBytes:)` has the same explicit-`nil` opt-out. A test double that
implements only `data(for:)` must select buffered collection explicitly;
bounded streaming fails closed instead of loading the entire body before
checking its ceiling. Oversized responses are rejected before cache storage or
decoding.

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

// 5.0
import InnoNetwork

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
constructing a path.

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
`HTTPBody` on every HEAD response and status `1xx`, `204`, `205`, or `304`.
Remove workarounds that attempted to decode server-supplied bytes for those
responses; the HTTP semantics take precedence over misleading
`Content-Length` or payload bytes.

Keep `swift-http-types` and OpenAPI Runtime models behind the optional
`InnoNetworkOpenAPI` product. The 5.0 migration does not replace core
`HTTPMethod`, `HTTPHeaders`, `Response`, or endpoint contracts with HTTPTypes.

## Expect cache-key and persistent-format reset

`ResponseCacheKey` no longer sorts query items. Query order can affect
signatures, duplicate-key behavior, and application routing, so
`/search?a=1&b=2` and `/search?b=2&a=1` are different cache identities in 5.0.
Review tests or custom invalidation code that assumed reordered queries would
collapse to one entry.

The persistent cache index is version 3. Opening a version-2 or unknown index
cold-resets the index and body store instead of migrating it. Treat the first
5.0 launch as a cold cache; do not rely on a persistent response surviving the
upgrade. This is cache eviction, not application-data migration.

## Re-audit diagnostic opt-ins and owned storage

`URLRequest.curlCommand()` is privacy-safe by default in 5.0:

- request bodies are omitted unless `CurlCommandOptions(includesBody: true)`;
- query keys remain visible, but values are redacted unless
  `includesQueryValues: true`;
- credential-like headers remain redacted; and
- userinfo and fragments are always removed.

Use body/query opt-ins only in a controlled local debugging path. They are not
appropriate defaults for production logs. Network event URLs follow the same
query/userinfo/fragment policy, mask JWT-like path values, and publish stable
failure categories instead of potentially sensitive error payload text.

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
addition to the remaining release checks.

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
- [ ] Accept or explicitly replace the new 5 MiB inline response cap; keep
  unbounded `nil` policies limited to reviewed payloads.
- [ ] Regenerate/review OpenAPI auth witnesses and remove HEAD/1xx/204/205/304
  response-body assumptions.
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
