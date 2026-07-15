# InnoNetwork Examples

This directory contains practical examples demonstrating how to use InnoNetwork in various real-world scenarios.

## Overview

InnoNetwork is a Swift package for type-safe network communication using async/await and Swift Concurrency. These examples cover common use cases from basic requests to complex workflows.

## Stability Tiers

Examples are categorized into two tiers, mirroring [API_STABILITY.md](../API_STABILITY.md):

- **Stable** — `BasicRequest`, `Auth`, `ErrorHandling`. The directory layout
  (Swift sources, `README.md`) and compileability against the current package
  are part of the 5.x SemVer-protected contract and are enforced by
  `Scripts/check_stable_examples.sh`. Copy these as a starting point with the
  same confidence as the Stable public API surface.
- **Provisionally Stable** — every other example. Their layout tracks the
  Provisionally Stable APIs they illustrate and may evolve in minor
  releases. The wording of any example is not contractual.

## Examples

### 1. [BasicRequest](./BasicRequest) — Stable

Learn the fundamentals of making HTTP requests with InnoNetwork.

**Covers:**
- GET requests (fetching data)
- POST requests (creating resources)
- PUT requests (full updates)
- PATCH requests (partial updates)
- DELETE requests (removing resources)
- Form URL-encoded requests
- Multipart/Form-data uploads
- Request/response models

**Best for:** Getting started with InnoNetwork, understanding basic request patterns

---

### 2. [ErrorHandling](./ErrorHandling) — Stable

Comprehensive guide to handling network errors gracefully.

**Covers:**
- NetworkError types and meanings
- Do-catch error handling patterns
- Accessing response data from errors
- Handling status code errors (404, 500, etc.)
- Handling network connectivity issues
- Cancellation handling

**Best for:** Building robust applications with proper error handling

---

### 3. [Auth](./Auth) — Stable

Wire `RefreshTokenPolicy` to a Keychain-backed token store with
single-flight refresh and one-time replay after `401`.

**Covers:**
- Keychain (`SecItem`) wrapper actor for serialized read/write
- `AuthService` actor that exposes `currentAccessToken` and `refreshAccessToken` closures
- `RefreshTokenPolicy` registration via `NetworkConfiguration.advanced(...)`
- Default Bearer `Authorization` token applicator and how to override it

**Best for:** Production apps that need a session-token lifecycle without pulling auth-storage dependencies into the library.

---

### 4. [DownloadManager](./DownloadManager)

Background-capable download sample with progress events and restore-oriented
manager setup.

**Covers:**
- Per-feature `DownloadManager`
- Destination selection
- Progress/event observation
- Background session restore shape

**Best for:** Apps that download media, documents, or offline assets.

---

### 5. [WebSocketChat](./WebSocketChat)

CLI chat-style sample for opening a WebSocket, sending text, and observing
server events.

**Covers:**
- `WebSocketManager.safeDefaults`
- Event stream consumption
- Send/receive loop
- Manual shutdown

**Best for:** Realtime features such as chat, collaboration, or live status.

---

### 6. [EventPolicyObserver](./EventPolicyObserver)

Observability sample for event delivery metrics and custom reporting.

**Covers:**
- Event delivery metrics reporters
- Logger/signpost style reporting
- Event hub backpressure policy visibility

**Best for:** Teams that need operational telemetry before production rollout.

---

### 7. [TargetTypeCatalog](./TargetTypeCatalog)

Moya-style enum catalog that maps each app-level route to a concrete
`APIDefinition` before execution.

**Covers:**
- Central route enum for incremental migrations
- Typed request/response endpoints behind each catalog case
- Result enum wrapping without erasing transport-time response types

**Best for:** Teams migrating a large TargetType catalog while keeping typed
endpoint execution in new code.

---

## Feature Recipes

- Auth refresh: [Auth](./Auth)
- Custom headers / pagination / CRUD walkthroughs: [App Networking Cookbook](../Sources/InnoNetwork/InnoNetwork.docc/Articles/AppNetworkingCookbook.md)
- TargetType-style catalogs: [TargetTypeCatalog](./TargetTypeCatalog)
- Response cache: [Caching Strategies](../Sources/InnoNetwork/InnoNetwork.docc/Articles/CachingStrategies.md)
- Background download: [DownloadManager](./DownloadManager)
- WebSocket chat: [WebSocketChat](./WebSocketChat)
- Observability: [EventPolicyObserver](./EventPolicyObserver)

## Compile-Time Integration Smokes

### [CoreSmoke](./CoreSmoke)

Compile-only package that depends on the root `InnoNetwork` product with
`traits: []`. CI uses it to verify that the macro declaration and compiler
plug-in compilation are excluded for core-only consumers. SwiftPM can still
resolve or fetch package-level manifest dependencies; traits are also unified
per package if another dependency enables them.

### [ConsumerSmoke](./ConsumerSmoke)

Compile-only package that protects public consumer-facing API shapes across the
three shipping products.

### [WrapperSmoke](./WrapperSmoke)

Compile-only package that protects wrapper-style integrations built on
future-candidate low-level execution hooks. These source shapes are not part of
the 5.x Stable public contract.

### [MacroUsage](./MacroUsage)

Compile-only package for the root package's default `Macros` trait. It imports
only `InnoNetwork` and verifies explicit endpoint structs with path values, GET
query inference, non-GET body inference, and required-auth scope generation.

### [TestSupportSmoke](./TestSupportSmoke)

Compile-only package that imports `InnoNetworkTestSupport` the way consumer test
targets do.

## Getting Started

### Prerequisites

- Swift 6.2+
- Xcode 26.0+

### Installation

Add InnoNetwork to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/InnoSquadCorp/InnoNetwork.git", from: "5.0.0")
]
```

### Running the Examples

1. Clone the InnoNetwork repository
2. Open the example folder you're interested in
3. Copy the `.swift` file to your project
4. Run the code

Or directly execute the example files as Swift scripts:

```bash
swift BasicRequest/BasicRequestExample.swift
```

## API Basics

### Configuration

First, configure your API:

```swift
import InnoNetwork

let client = DefaultNetworkClient(
    configuration: NetworkConfiguration.safeDefaults(
        baseURL: URL(string: "https://api.example.com/v1")!
    )
)
```

### Making Requests

Define your API endpoint:

```swift
struct GetUser: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = User

    var method: HTTPMethod { .get }
    var path: String { "/user/1" }
}

let user = try await client.request(GetUser())
```

### With Parameters

```swift
struct CreatePost: APIDefinition {
    struct PostParameter: Encodable, Sendable {
        let title: String
        let body: String
    }

    typealias Parameter = PostParameter
    typealias APIResponse = Post

    let parameters: PostParameter?
    var method: HTTPMethod { .post }
    var path: String { "/posts" }

    init(title: String, body: String) {
        self.parameters = PostParameter(title: title, body: body)
    }
}
```

### With Custom Headers

```swift
var headers: HTTPHeaders {
    var customHeaders = HTTPHeaders.default
    customHeaders.add(.authorization(bearerToken: "token"))
    customHeaders.add(.contentType("application/json"))
    return customHeaders
}
```

### Form URL-encoded

```swift
struct LoginRequest: APIDefinition {
    struct LoginParameter: Encodable, Sendable {
        let email: String
        let password: String
    }

    typealias Parameter = LoginParameter
    typealias APIResponse = AuthResponse

    let parameters: LoginParameter?
    var method: HTTPMethod { .post }
    var path: String { "/login" }
    var transport: TransportPolicy<AuthResponse> { .formURLEncoded() }

    init(email: String, password: String) {
        self.parameters = LoginParameter(email: email, password: password)
    }
}
```

### Multipart/Form-data (File Upload)

```swift
struct UploadImage: MultipartAPIDefinition {
    typealias APIResponse = UploadResponse

    var multipartFormData: MultipartFormData {
        var formData = MultipartFormData()
        formData.append("My Image", name: "title")
        formData.append(
            imageData,
            name: "file",
            fileName: "image.jpg",
            mimeType: "image/jpeg"
        )
        return formData
    }

    var method: HTTPMethod { .post }
    var path: String { "/upload" }
}

let response = try await client.upload(UploadImage())
```

### Error Handling

```swift
do {
    let response = try await client.request(MyAPIRequest())
    print("Success: \(response)")
} catch {
    switch error {
    case .statusCode(let response):
        print("HTTP Error: \(response.statusCode)")
    case .decoding(let stage, let decodingError, _):
        print("Decoding Error (\(stage)): \(decodingError)")
    case .reachability(let reason, _, _):
        print("Reachability Error: \(reason)")
    default:
        print("Other Error: \(error)")
    }
}
```

### Download (InnoNetworkDownload)

```swift
import InnoNetworkDownload

// Per-feature manager with a unique session identifier. 4.0.0 removes
// `DownloadManager.shared`, so construction is explicit at the feature boundary.
let manager = try DownloadManager.make(
    configuration: .safeDefaults(sessionIdentifier: "com.example.app.media")
)

// Start download
let task = await manager.download(
    url: URL(string: "https://example.com/file.zip")!,
    toDirectory: documentsDirectory
)

// AsyncSequence events
for await event in await manager.events(for: task) {
    switch event {
    case .progress(let progress):
        print("Progress: \(progress.percentCompleted)%")
    case .completed(let url):
        print("Downloaded to: \(url)")
    case .failed(let error):
        print("Failed: \(error)")
    default:
        break
    }
}

// Pause/Resume
await manager.pause(task)
await manager.resume(task)
```

## Contributing

Found a bug or want to add an example? Contributions are welcome!

## License

MIT License - See LICENSE file for details.

## Support

- GitHub Issues: https://github.com/InnoSquadCorp/InnoNetwork/issues
- Documentation: See individual example READMEs
