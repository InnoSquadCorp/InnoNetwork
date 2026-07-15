# App Networking Cookbook

Compose auth refresh, response caching, background downloads, and WebSocket
observation without forcing one global manager.

## Feature Container

Keep request execution, downloads, and sockets feature-scoped. This lets each
feature choose its own cache, background session identifier, and reconnect
policy while sharing the same auth token store.

```swift
import Foundation
import InnoNetwork
import InnoNetworkDownload
import InnoNetworkWebSocket
import InnoNetworkPersistentCache

struct AppNetworking: Sendable {
    let api: DefaultNetworkClient
    let downloads: DownloadManager
    let realtime: WebSocketManager

    static func make(
        baseURL: URL,
        tokenStore: TokenStore,
        cacheDirectory: URL
    ) async throws -> AppNetworking {
        let refresh = RefreshTokenPolicy(
            currentToken: { try await tokenStore.currentAccessToken() },
            refreshToken: { try await tokenStore.refreshAccessToken() }
        )
        let cache = try PersistentResponseCache(
            configuration: .init(directoryURL: cacheDirectory)
        )

        let apiConfiguration = NetworkConfiguration.advanced(
            baseURL: baseURL,
            resilience: ResiliencePack(
                bodyBuffering: .streaming(maxBytes: 5 * 1024 * 1024)
            ),
            auth: AuthPack(refreshToken: refresh),
            cache: CachePack(
                responseCachePolicy: .cacheFirst(maxAge: .seconds(300)),
                responseCache: cache
            )
        )

        let downloadConfiguration = DownloadConfiguration.advanced { builder in
            builder.sessionIdentifier = "com.example.app.downloads.media"
            builder.persistenceCompactionPolicy = .init()
        }

        return AppNetworking(
            api: DefaultNetworkClient(configuration: apiConfiguration),
            downloads: try DownloadManager.make(configuration: downloadConfiguration),
            realtime: WebSocketManager(configuration: .safeDefaults())
        )
    }
}
```

`PersistentResponseCache` refuses credential-like request keys,
`Cache-Control: private`, and `Set-Cookie` responses by default, and applies
`.completeUntilFirstUserAuthentication` data protection to its files on iOS,
tvOS, watchOS, and visionOS. Even with
`storesAuthenticatedResponses: true`, responses to requests carrying
`Authorization` are stored only when the origin explicitly permits it with
`Cache-Control: public`, `must-revalidate`, or `s-maxage`.
`dataProtectionClass: .none` explicitly requests `NSFileProtectionNone` on
cache-owned paths on those platforms instead of skipping protection updates. If a
cookie-authenticated endpoint should be cached, make that choice in a
feature-specific cache product and prefer explicit request headers or origin
`private`/`no-store` directives; cookies injected by `URLSession` storage are
not fully visible at the cache abstraction boundary.

## Typed Auth Boundary

Use `.authentication(.required)` for requests that must not run unless the
client has a refresh policy capable of supplying a token.

```swift
struct Profile: Decodable, Sendable {
    let id: String
    let displayName: String
}

let profile = try await networking.api.request(
    EndpointBuilder<EmptyResponse>
        .get("/me")
        .authentication(.required)
        .decoding(Profile.self)
)
```

Anonymous calls choose `.anonymous` explicitly:

```swift
let catalog = try await networking.api.request(
    EndpointBuilder<EmptyResponse>
        .get("/catalog")
        .authentication(.anonymous)
        .decoding(Catalog.self)
)
```

## Background Download

Download restoration is explicit at app launch. Public download APIs already
wait on the internal restore gate, but `waitForRestoration()` is useful when
the UI wants to block until persisted tasks have been reconciled.

```swift
let restored = await networking.downloads.waitForRestoration()
if restored {
    let task = await networking.downloads.download(
        url: mediaURL,
        to: destinationURL
    )
    for await event in await networking.downloads.events(for: task) {
        render(event)
    }
}
```

Paused tasks keep `resumeData` in the append-log store when URLSession provides
it. Completed, resumed, and cancelled tasks clear that data.

## WebSocket Observation

Create a feature-scoped `WebSocketManager` instance for each realtime owner.

```swift
let socket = try await networking.realtime.connect(url: socketURL)

Task {
    for await event in await networking.realtime.events(for: socket) {
        observe(event)
    }
}
```

When a feature signs out, cancel its requests, disconnect its socket, and clear
any feature-owned cache directory together. That keeps auth, cache, download,
and realtime state aligned with the same user-session lifetime.
