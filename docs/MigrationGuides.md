# Migration Guides

This page is a practical map for moving existing Apple-client networking code
onto InnoNetwork without rewriting every endpoint at once.

> **Release status:** This page describes the unreleased 5.0 preview on `main`.
> `4.0.0` remains the latest tagged stable release. Use the draft migration
> guide to prepare and evaluate source changes, not as evidence that `5.0.0`
> has shipped.

## From InnoNetwork 4.x

Start with the [draft 5.0 migration guide](Migration-5.0.0.md). The required source
changes are concentrated in four areas: zero-argument
`RequestExecutionNext.execute()`, configuration packs instead of the seven
deprecated `.with(...)` modifiers, app-owned reducer vocabulary, and
body-aware `RequestSigner` implementations. The guide also documents stricter
redirect defaults and the cache/coalescing boundary for signed requests.

## From URLSession

Start by wrapping one endpoint in `APIDefinition` and keep the same model
types. `DefaultNetworkClient` owns URL construction, policy application,
status validation, and decoding.

```swift
@APIDefinition(method: .get, path: "/me", auth: .anonymous)
struct GetProfile {
    typealias APIResponse = Profile
}

let client = DefaultNetworkClient(
    configuration: .safeDefaults(
        baseURL: URL(string: "https://api.example.com")!
    )
)

let profile = try await client.request(GetProfile())
```

Migration notes:

- Move request construction into endpoint types or `EndpointBuilder` calls.
- Keep app-specific token storage outside the library and wire it through
  `RefreshTokenPolicy`.
- Replace ad hoc retry loops with `RetryPolicy` / `ExponentialBackoffRetryPolicy`.
- Use `NetworkEventObserving` instead of scattering logging around call sites.

## From Alamofire

Alamofire projects usually have adapters, retriers, request modifiers, and
response serializers. Move those concepts one layer at a time:

| Alamofire concept | InnoNetwork target |
|---|---|
| `Session` | `DefaultNetworkClient` |
| `RequestInterceptor` auth adapter/retrier | `RefreshTokenPolicy` plus request interceptors |
| `ParameterEncoder` | `EndpointBuilder` or `TransportPolicy` / endpoint `parameters` |
| `ResponseSerializer` | `ResponseDecodingStrategy` or `AnyResponseDecoder` |
| `EventMonitor` | `NetworkEventObserving` |

```swift
let configuration = NetworkConfiguration.advanced(
    baseURL: URL(string: "https://api.example.com")!,
    resilience: ResiliencePack(retry: ExponentialBackoffRetryPolicy(maxRetries: 2)),
    auth: AuthPack(refreshToken: refreshPolicy),
    observability: ObservabilityPack(eventObservers: [analyticsObserver])
)
let client = DefaultNetworkClient(configuration: configuration)
```

Migrate leaf endpoints first. Keep Alamofire for flows that still need
custom session behavior, then delete the compatibility layer when the last
caller moves to typed endpoints. For a smaller before/after, use
[`MigrationFromAlamofire.md`](MigrationFromAlamofire.md).

## From Moya

Moya's `TargetType` maps cleanly to a small `APIDefinition` or `EndpointBuilder`
factory. Keep target-style enums if they are useful to the app, but make the
network boundary return typed endpoint definitions instead of generic tasks.

```swift
enum UserEndpoints {
    static func profile(id: String) -> EndpointBuilder<UserDTO> {
        EndpointBuilder<EmptyResponse>
            .get("/users/\(id)")
            .authentication(.anonymous)
            .decoding(UserDTO.self)
    }

    static func posts(id: String, page: Int) -> EndpointBuilder<[PostDTO]> {
        EndpointBuilder<EmptyResponse>
            .get("/users/\(id)/posts")
            .query(["page": page])
            .authentication(.anonymous)
            .decoding([PostDTO].self)
    }
}
```

Migration notes:

- Replace plugin side effects with `NetworkEventObserving`, request
  interceptors, or explicit app services.
- Replace stubbing with `InnoNetworkTestSupport` in test targets.
- Keep pagination as app/domain logic that repeatedly calls typed endpoints.
- Prefer `EndpointBuilder` for simple targets and `APIDefinition` when an endpoint
  owns custom transport, multipart upload, streaming, or interceptors.
- For a smaller before/after, use [`MigrationFromMoya.md`](MigrationFromMoya.md).

## Removed Auth-Scope Generics

The InnoNetwork 5.0 preview replaces the phantom auth-scope generic with the runtime
``SessionAuthentication`` policy. Keep the response type as the builder's only
generic argument and choose authentication explicitly in the builder chain:

| 4.x usage | 5.0 preview replacement |
| --- | --- |
| 4.x public-scope builder | `EndpointBuilder<Response>` plus `.authentication(.anonymous)` |
| 4.x auth-required builder | `EndpointBuilder<Response>` plus `.authentication(.required)` |
| 4.x `typealias Auth = ...` witness | `var sessionAuthentication: SessionAuthentication` |

Builder entry points still start from `EndpointBuilder<EmptyResponse>`:

```swift
let publicEndpoint = EndpointBuilder<EmptyResponse>
    .get("/catalog")
    .authentication(.anonymous)
    .decoding(Catalog.self)

let authEndpoint = EndpointBuilder<EmptyResponse>
    .get("/me")
    .authentication(.required)
    .decoding(Profile.self)
```

Use `.optional` only when a configured refresh policy may attach a token but
the request is also allowed to proceed anonymously. A manual
`APIDefinition` must expose the equivalent
`sessionAuthentication: SessionAuthentication` witness.

## Feature Recipes

- Auth refresh: [Auth Refresh](../Sources/InnoNetwork/InnoNetwork.docc/Articles/AuthRefresh.md) and [Examples/Auth](../Examples/Auth).
- Basic typed requests: [Examples/BasicRequest](../Examples/BasicRequest).
- Response cache: [Caching Strategies](../Sources/InnoNetwork/InnoNetwork.docc/Articles/CachingStrategies.md).
- Background download: [Examples/DownloadManager](../Examples/DownloadManager).
- WebSocket chat: [Examples/WebSocketChat](../Examples/WebSocketChat).
- Observability: [Examples/EventPolicyObserver](../Examples/EventPolicyObserver) and [Event Delivery Policy](../Sources/InnoNetwork/InnoNetwork.docc/Articles/EventDeliveryGuide.md).

## Platform Trade-off

InnoNetwork intentionally requires Swift 6.2+ and current Apple OS baselines.
That buys stricter concurrency checking, modern URLSession behavior, and fewer
compatibility shims. Apps that still ship older OS versions should keep a thin
URLSession or existing-client bridge at the app boundary until their deployment
target can move.
