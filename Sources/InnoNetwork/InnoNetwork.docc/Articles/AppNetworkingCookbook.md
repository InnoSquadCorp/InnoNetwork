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

        let apiConfiguration = NetworkConfiguration.advanced(baseURL: baseURL) { builder in
            builder.refreshTokenPolicy = refresh
            builder.responseCachePolicy = .cacheFirst(maxAge: .seconds(300))
            builder.responseCache = cache
            builder.responseBodyBufferingPolicy = .streaming(maxBytes: 5 * 1024 * 1024)
        }

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

`PersistentResponseCache` refuses authenticated and `Set-Cookie` responses by
default. If an authenticated endpoint should be cached, make that choice in a
feature-specific cache product rather than turning the default disk cache into
a shared credential store.

## Typed Auth Boundary

Use `AuthenticatedEndpoint` for requests that must not run unless the client
has a refresh policy.

```swift
struct Profile: Decodable, Sendable {
    let id: String
    let displayName: String
}

let profile = try await networking.api.request(
    AuthenticatedEndpoint.get("/me").decoding(Profile.self)
)
```

Public calls can keep using `Endpoint`:

```swift
let catalog = try await networking.api.request(
    Endpoint.get("/catalog").decoding(Catalog.self)
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

Prefer a feature-scoped `WebSocketManager` instance over
`WebSocketManager.shared`.

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
