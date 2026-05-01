# Migration Guides

This page is a practical map for moving existing Apple-client networking code
onto InnoNetwork without rewriting every endpoint at once.

## From URLSession

Start by wrapping one endpoint in `APIDefinition` and keep the same model
types. `DefaultNetworkClient` owns URL construction, policy application,
status validation, and decoding.

```swift
struct GetProfile: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Profile

    var method: HTTPMethod { .get }
    var path: String { "/me" }
}

let client = DefaultNetworkClient(
    configuration: .safeDefaults(
        baseURL: URL(string: "https://api.example.com")!
    )
)

let profile = try await client.request(GetProfile())
```

Migration notes:

- Move request construction into endpoint types or `Endpoint` builder calls.
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
| `ParameterEncoder` | `TransportPolicy` / endpoint `parameters` |
| `ResponseSerializer` | `ResponseDecodingStrategy` or `AnyResponseDecoder` |
| `EventMonitor` | `NetworkEventObserving` |

```swift
let client = DefaultNetworkClient(
    configuration: .advanced(
        baseURL: URL(string: "https://api.example.com")!
    ) { builder in
        builder.refreshTokenPolicy = refreshPolicy
        builder.retryPolicy = ExponentialBackoffRetryPolicy(maxRetries: 2)
        builder.eventObservers = [analyticsObserver]
    }
)
```

Migrate leaf endpoints first. Keep Alamofire for flows that still need
custom session behavior, then delete the compatibility layer when the last
caller moves to typed endpoints.

## From Moya

Moya's `TargetType` maps cleanly to a small `APIDefinition` or `Endpoint`
factory. Keep target-style enums if they are useful to the app, but make the
network boundary return typed endpoint definitions instead of generic tasks.

```swift
enum UserEndpoints {
    static func profile(id: String) -> Endpoint<UserDTO> {
        Endpoint.get("/users/\(id)").decoding(UserDTO.self)
    }

    static func posts(id: String, page: Int) -> Endpoint<[PostDTO]> {
        Endpoint.get("/users/\(id)/posts")
            .query(["page": page])
            .decoding([PostDTO].self)
    }
}
```

Migration notes:

- Replace plugin side effects with `NetworkEventObserving`, request
  interceptors, or explicit app services.
- Replace stubbing with `InnoNetworkTestSupport` in test targets.
- Keep pagination as app/domain logic that repeatedly calls typed endpoints.
- Prefer `Endpoint` for simple targets and `APIDefinition` when an endpoint
  owns custom transport, multipart upload, streaming, or interceptors.

## Feature Recipes

- Auth refresh: [Auth Refresh](../Sources/InnoNetwork/InnoNetwork.docc/Articles/AuthRefresh.md) and [Examples/Auth](../Examples/Auth).
- Pagination and CRUD: [Examples/RealWorldAPI](../Examples/RealWorldAPI).
- Response cache: [Caching Strategies](../Sources/InnoNetwork/InnoNetwork.docc/Articles/CachingStrategies.md).
- Background download: [Examples/DownloadManager](../Examples/DownloadManager).
- WebSocket chat: [Examples/WebSocketChat](../Examples/WebSocketChat).
- Observability: [Examples/EventPolicyObserver](../Examples/EventPolicyObserver) and [Event Delivery Policy](../Sources/InnoNetwork/InnoNetwork.docc/Articles/EventDeliveryPolicy.md).

## Platform Trade-off

InnoNetwork intentionally requires Swift 6.2+ and current Apple OS baselines.
That buys stricter concurrency checking, modern URLSession behavior, and fewer
compatibility shims. Apps that still ship older OS versions should keep a thin
URLSession or existing-client bridge at the app boundary until their deployment
target can move.
