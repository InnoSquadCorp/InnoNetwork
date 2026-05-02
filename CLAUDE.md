# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Developer Guidelines

### Language Policy
- Developer is Korean.
- Respond in Korean unless explicitly requested otherwise.
- PR description always in Korean.

### Project Context
- This is a network library, not a UI framework.
- Focus on async/await patterns, thread safety, and type safety.
- Avoid UI-related considerations (main thread for UI updates, etc.).

### Code Quality Standards
- **Type Safety**: Never use `as any`, `@ts-ignore`, or similar type suppression
- **Error Handling**: No empty catch blocks
- **Concurrency**: Use actors for shared state, make types Sendable where appropriate
- **Testing**: Write tests using Swift Testing framework

### Git and Version Control
- Branch name in English
- Commit message in English
- DO NOT git add unstaged changes unless specified
- Keep commits focused and logically grouped

## Project Overview

InnoNetwork is a type-safe Swift network library:

**Core Features:**
- Async/await based requests
- Type-safe request/response via generics
- Content types: JSON, Form URL-encoded, Multipart/Form-data
- Interceptors for request/response modification
- Configurable retry policies

**Download Module (InnoNetworkDownload):**
- Background downloads
- Pause/resume support
- Automatic retry
- AsyncSequence event streams
- Actor-based thread safety

**Platform:**
- Swift 6.2+ (package enforces `swiftLanguageMode(.v6)`)
- iOS 18.0+ / macOS 15.0+ / tvOS 18.0+ / watchOS 11.0+ / visionOS 2.0+
- Full Sendable compliance

## Development Commands

```bash
# Build
swift build

# Test
swift test

# Test with coverage
swift test --enable-code-coverage --parallel

# List tests
swift test --list-tests
```

## Architecture

### Core Module (InnoNetwork)

```
Sources/InnoNetwork/
├── API.swift                    # APIConfigure 프로토콜
├── APIDefinition.swift          # APIDefinition, MultipartAPIDefinition
├── DefaultNetworkClient.swift   # NetworkClient 구현
├── Model/
│   ├── MultipartFormData.swift
│   ├── EmptyParameter.swift
│   ├── EmptyResponse.swift
│   └── Response.swift
├── RequestInterceptor.swift
├── ResponseInterceptor.swift
├── NetworkError.swift
└── NetworkLogger.swift
```

### Download Module (InnoNetworkDownload)

```
Sources/InnoNetworkDownload/
├── DownloadManager.swift        # 메인 매니저 (async callbacks + AsyncSequence)
├── DownloadTask.swift           # actor 기반 개별 작업
├── DownloadConfiguration.swift
├── DownloadState.swift
└── DownloadSessionDelegate.swift
```

## Common Patterns

### API Definition

```swift
// Simple GET
struct GetUser: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = User

    var method: HTTPMethod { .get }
    var path: String { "/user/\(id)" }
    let id: Int

    init(id: Int) { self.id = id }
}

// With parameters
struct CreatePost: APIDefinition {
    struct Params: Encodable, Sendable { let title: String; let body: String }
    typealias Parameter = Params
    typealias APIResponse = Post

    let parameters: Params?
    var method: HTTPMethod { .post }
    var path: String { "/posts" }

    init(title: String, body: String) {
        self.parameters = Params(title: title, body: body)
    }
}

// Multipart upload
struct UploadPhoto: MultipartAPIDefinition {
    typealias APIResponse = UploadResponse

    var multipartFormData: MultipartFormData {
        MultipartFormData()
            .addText(name: "title", value: title)
            .addFile(data: imageData, fileName: "photo.jpg", name: "image", mimeType: "image/jpeg")
    }

    var method: HTTPMethod { .post }
    var path: String { "/upload" }
    let title: String
    let imageData: Data

    init(title: String, imageData: Data) {
        self.title = title
        self.imageData = imageData
    }
}
```

### Using the Client

```swift
let client = try DefaultNetworkClient(configuration: MyAPI())

// Regular request
let user = try await client.request(GetUser(id: 1))

// Multipart upload
let response = try await client.upload(UploadPhoto(title: "My Photo", imageData: data))
```

### Download

```swift
// Construct one DownloadManager per feature with a unique session identifier.
// 4.0.0 removed the global `DownloadManager.shared`; manage lifetimes via DI.
let manager = try DownloadManager.make(
    configuration: .safeDefaults(sessionIdentifier: "com.example.app.media")
)

// Start download
let task = await manager.download(url: url, to: destination)

// AsyncSequence events
for await event in manager.events(for: task) {
    switch event {
    case .progress(let progress):
        print(progress.percentCompleted)
    case .completed(let url):
        print("Downloaded: \(url)")
    case .failed(let error):
        print("Failed: \(error)")
    default:
        break
    }
}

// Or use callbacks
manager.onProgress = { task, progress in
    print(progress.percentCompleted)
}

// Control
await manager.pause(task)
await manager.resume(task)
await manager.cancel(task)
```

### Interceptors

```swift
struct AuthInterceptor: RequestInterceptor {
    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

struct GetProfile: APIDefinition {
    var requestInterceptors: [RequestInterceptor] { [AuthInterceptor()] }
    // ...
}
```

## Testing Guidelines

- Use Swift Testing framework (`@Suite`, `@Test`)
- Tests are async-compatible
- Mock URLSession for network tests
- Test error cases and success cases
- Download tests verify state transitions
