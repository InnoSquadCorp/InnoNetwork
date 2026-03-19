# InnoNetwork

InnoNetwork is a Swift package for type-safe networking on Apple platforms. It provides three public products:

- `InnoNetwork` for request/response APIs
- `InnoNetworkDownload` for download lifecycle management
- `InnoNetworkWebSocket` for connection-oriented realtime flows

The package is built around Swift Concurrency, explicit transport policies, and operational visibility that can scale from app prototypes to production clients.

## Quick Start

### Install

```swift
dependencies: [
    .package(url: "https://github.com/InnoSquad/InnoNetwork.git", from: "3.0.0")
]
```

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
- retry coordination and interceptor boundaries
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

## Platform Matrix

- iOS 18.0+
- macOS 15.0+
- tvOS 18.0+
- watchOS 11.0+
- visionOS 2.0+
- Swift 6.2+

The package intentionally targets current Apple platform releases. That lets the codebase rely on modern Swift Concurrency semantics, stricter Sendable checking, and the latest URLSession and platform APIs without compatibility shims.

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

let download = DownloadConfiguration.safeDefaults()

let socket = WebSocketConfiguration.safeDefaults()

let tunedNetwork = NetworkConfiguration.advanced(
    baseURL: URL(string: "https://api.example.com")!
) { builder in
    builder.timeout = 30
    builder.retryPolicy = ExponentialBackoffRetryPolicy()
    builder.trustPolicy = .systemDefault
}
```

## Error Handling

InnoNetwork favors explicit transport errors over opaque failures.

```swift
do {
    let user = try await client.request(GetUser())
    print(user)
} catch let error as NetworkError {
    switch error {
    case .invalidBaseURL(let url):
        print("Invalid base URL: \\(url)")
    case .invalidRequestConfiguration(let message):
        print("Invalid request configuration: \\(message)")
    case .statusCode(let response):
        print("Unexpected status code: \\(response.statusCode)")
    case .objectMapping(let underlying, _):
        print("Decoding failed: \\(underlying)")
    case .trustEvaluationFailed(let reason):
        print("Trust evaluation failed: \\(reason)")
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

The 3.x line follows semantic versioning.

- Stable public API: [API_STABILITY.md](API_STABILITY.md)
- Release rules and compatibility policy: [docs/RELEASE_POLICY.md](docs/RELEASE_POLICY.md)
- Migration expectations: [docs/MIGRATION_POLICY.md](docs/MIGRATION_POLICY.md)

`safeDefaults` is the recommended public path. `default` aliases remain available for compatibility, but new examples and new integrations should prefer `safeDefaults`.

## Benchmarks

The repository includes a dedicated benchmark runner for quick local comparisons.

```bash
swift run InnoNetworkBenchmarks --quick
swift run InnoNetworkBenchmarks --json-path /tmp/innonetwork-bench.json
```

Benchmark governance, baseline policy, and CI posture are documented in [Benchmarks/README.md](Benchmarks/README.md).

## Documentation

- Examples: [Examples/README.md](Examples/README.md)
- API Stability: [API_STABILITY.md](API_STABILITY.md)
- Release Policy: [docs/RELEASE_POLICY.md](docs/RELEASE_POLICY.md)
- Migration Policy: [docs/MIGRATION_POLICY.md](docs/MIGRATION_POLICY.md)
- Latest Release Notes: [docs/releases/3.0.0.md](docs/releases/3.0.0.md)
- Roadmap: [docs/ROADMAP.md](docs/ROADMAP.md)

## Support

InnoNetwork follows a lightweight maintainer model.

- Support policy: [SUPPORT.md](SUPPORT.md)
- Contributing guide: [CONTRIBUTING.md](CONTRIBUTING.md)
- Security reporting: [SECURITY.md](SECURITY.md)
- Changelog: [CHANGELOG.md](CHANGELOG.md)
- Code of Conduct: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)

## License

MIT. See [LICENSE](LICENSE).
