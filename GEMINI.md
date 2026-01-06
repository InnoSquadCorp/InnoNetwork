# InnoNetwork Project

## Project Overview

InnoNetwork is a type-safe Swift network library using async/await and Swift Concurrency. It provides:

- **Core REST API**: JSON, Form URL-encoded, Multipart/Form-data support
- **Download Module**: Background downloads, pause/resume, retry with AsyncSequence events
- **Swift 6.2 Concurrency**: Full Sendable compliance, actor-based thread safety

## Building and Running

The project is a Swift Package Manager (SPM) package.

### Building

```bash
swift build
```

### Testing

```bash
swift test

# With code coverage
swift test --enable-code-coverage --parallel
```

## Development Conventions

### Code Style

- Swift 6.2+ with full Sendable compliance
- No `@unchecked Sendable` unless absolutely necessary (e.g., NSObject subclasses)
- No type error suppression (`as any`, `@ts-ignore`, `@ts-expect-error`)
- No empty catch blocks
- Actor-based thread safety for shared state

### Testing

- Uses Swift Testing framework (`@Suite`, `@Test`)
- 37+ tests covering core functionality and download module
- Tests are async-compatible

### Modules

```
InnoNetwork/
├── Sources/
│   ├── InnoNetwork/              # Core (REST API)
│   │   ├── API.swift             # APIConfigure 프로토콜
│   │   ├── APIDefinition.swift   # APIDefinition, MultipartAPIDefinition
│   │   ├── DefaultNetworkClient.swift
│   │   ├── Model/
│   │   │   ├── MultipartFormData.swift
│   │   │   ├── EmptyParameter.swift
│   │   │   ├── EmptyResponse.swift
│   │   │   └── Response.swift
│   │   └── ... (interceptors, error, logger 등)
│   │
│   └── InnoNetworkDownload/      # Download 모듈 (별도 product)
│       ├── DownloadManager.swift
│       ├── DownloadTask.swift    # actor 기반
│       ├── DownloadConfiguration.swift
│       ├── DownloadState.swift
│       └── DownloadSessionDelegate.swift
│
└── Tests/
    ├── InnoNetworkTests/
    └── InnoNetworkDownloadTests/
```

### Key Technologies

- **Swift Concurrency**: async/await, actors, Sendable
- **URLSession**: Core networking with protocol DI for testability
- **Swift Testing**: Modern test framework

## Code Patterns

### API Definition

```swift
// Regular API
struct GetUser: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = User

    var method: HTTPMethod { .get }
    var path: String { "/user/1" }
}

// Multipart/Form-data
struct UploadImage: MultipartAPIDefinition {
    typealias APIResponse = UploadResponse

    var multipartFormData: MultipartFormData {
        MultipartFormData()
            .addText(name: "title", value: "My Image")
            .addFile(data: data, fileName: "image.jpg", name: "file", mimeType: "image/jpeg")
    }

    var method: HTTPMethod { .post }
    var path: String { "/upload" }
}
```

### Download (AsyncSequence)

```swift
let manager = DownloadManager.shared
let task = await manager.download(url: url, to: destination)

for await event in manager.events(for: task) {
    switch event {
    case .progress(let progress):
        print("Progress: \(progress.percentCompleted)%")
    case .completed(let url):
        print("Downloaded: \(url)")
    case .failed(let error):
        print("Failed: \(error)")
    default:
        break
    }
}
```
