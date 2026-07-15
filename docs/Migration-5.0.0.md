# Migration Guide: 5.0.0

InnoNetwork 5.0 makes request identity, signing, redirects, and configuration
composition explicit. The changes below intentionally remove 4.x migration
bridges that could make the bytes sent on the wire differ from the request a
policy observed.

## Required source changes

| 4.x usage | 5.0 replacement |
| --- | --- |
| `RequestExecutionNext.execute(request)` | `RequestExecutionNext.execute()` |
| `.with(retry:)`, `.with(circuitBreaker:)`, `.with(coalescing:)`, `.with(executionPolicies:)` | `ResiliencePack` passed to `NetworkConfiguration.advanced(...)` |
| `.with(refresh:)` | `AuthPack(refreshToken:)` |
| `.with(eventObservers:)` | `ObservabilityPack(eventObservers:)` |
| `.with(cache:)` | `CachePack(responseCache:)` |
| Public `StateReducer` / `StateReduction` | An application-owned reducer type, or a feature-local reducer |
| Body signing in `RequestInterceptor` | `RequestSigner.signatureHeaders(for:body:)` |
| `await manager.retry(task)` while continuing to use `task` | Capture `WebSocketRetryResult?`, use its fresh `task`, and consume its pre-registered `events` stream |
| `import InnoNetworkCodegen` | Remove it; the attached macro ships from `import InnoNetwork` |
| `@APIDefinition(method:path:)` | Add the mandatory `auth: .public` or `.required` argument |
| `#endpoint(method, path, as: Response.self)` | Use a named macro-assisted endpoint struct or runtime `EndpointBuilder` |
| Passing an optional directly to `EndpointPathEncoding.percentEncodedSegment` | Unwrap it and define the nil behavior before encoding |

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

## Redirect defaults are stricter

The default redirect policy now denies HTTPS-to-HTTP downgrade, strips the
expanded sensitive-header set when authority changes, and denies cross-origin
`307`/`308` redirects for unsafe methods. Signed requests deny automatic
redirects even when the target is same-origin.

If an API contract requires a redirect that the defaults reject, treat the 3xx
as application data, validate the target explicitly, and start a new typed
request. Do not forward authorization, cookie, proxy authorization, API-key,
or signature headers across authority boundaries.

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

@APIDefinition(method: .get, path: "/users/{id}", auth: .public)
struct GetUser {
    typealias APIResponse = User
    let id: Int
}
```

This is macro-first without making the macro the endpoint abstraction. The
explicit struct remains the source of truth: `APIResponse`, stored request
inputs, and any custom headers, interceptors, transport, decoder, or policy
remain on it. The macro derives conformance, method, percent-encoded path, auth
scope, and the supported simple payload shape. A stored `query` is inferred
only for GET; a stored `body` is inferred only for non-GET methods. Declare the
complete `Parameter` + `parameters` pair when the endpoint needs a custom
payload contract.

Definitions now fail closed when response or auth intent is missing, a path is
unsafe or references an unsupported property, or generated witnesses conflict.
Optional values are no longer accepted by the public path-segment encoder;
unwrap them and decide whether nil means omit, substitute, or reject before
constructing a path.

Consumers that do not use macros can disable the default trait:

```swift
.package(
    url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
    from: "5.0.0",
    traits: []
)
```

This excludes the macro declaration and compiler plug-in products from the
target graph and compilation. SwiftPM can still resolve or fetch the
manifest-level `swift-syntax` dependency. Traits are unified per package across
the resolved graph, so every dependency path must keep `Macros` disabled for a
core-only build.

## Pre-flight checklist

- [ ] Replace every `next.execute(request)` call with `next.execute()` and
  move adaptation to `RequestInterceptor`.
- [ ] Replace the seven `.with(...)` modifiers with configuration packs.
- [ ] Move adopter-defined `StateReducer` conformances to app-owned types.
- [ ] Move body-dependent authentication to `RequestSigner`.
- [ ] Verify any redirect-dependent endpoint against the stricter policy.
- [ ] Exercise signed data and file uploads, retries, and refresh replays.
- [ ] Capture every `WebSocketManager.retry(_:)` result, consume its returned
  event stream, and attach any additional listeners to its fresh task.
- [ ] Keep automatic-reconnect observers on the existing task; do not create a
  second task for a transport-generation change.
- [ ] Remove the nested codegen package/import, add explicit `auth:` to every
  macro endpoint, and replace `#endpoint` call sites.
- [ ] Decide whether each optional path value is omitted, substituted, or
  rejected before segment encoding.
- [ ] If using `traits: []`, verify no other dependency path re-enables the
  default `Macros` trait.

## See also

- [API_STABILITY.md](../API_STABILITY.md) for the 5.x compatibility contract.
- [Migration-4.0.0.md](Migration-4.0.0.md) for the original public baseline.
- [MIGRATION_POLICY.md](MIGRATION_POLICY.md) for the general migration policy.
