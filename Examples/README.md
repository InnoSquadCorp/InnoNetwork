# InnoNetwork Examples

This directory contains practical examples demonstrating how to use InnoNetwork in various real-world scenarios.

## Overview

InnoNetwork is a Swift package for type-safe network communication using async/await and Swift Concurrency. These examples cover common use cases from basic requests to complex workflows.

## Examples

### 1. [BasicRequest](./BasicRequest)

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

### 2. [ErrorHandling](./ErrorHandling)

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

### 3. [CustomHeaders](./CustomHeaders)

Learn how to customize HTTP headers for authentication, content negotiation, and more.

**Covers:**
- Basic authentication
- Bearer token authentication
- Custom Content-Type headers
- User-Agent customization
- Accept-Language and Accept-Encoding
- Multiple custom headers in a single request

**Best for:** Working with APIs that require specific headers, authentication

---

### 4. [RealWorldAPI](./RealWorldAPI)

Real-world scenarios you'll encounter in actual application development.

**Covers:**
- User authentication flow
- Paginated data fetching
- CRUD operations (Create, Read, Update, Delete)
- Fetching related data (post + comments)
- User profile management
- Batch processing multiple requests

**Best for:** Learning complete application workflows, building full-featured apps

---

## Compile-Time Integration Smokes

### [ConsumerSmoke](./ConsumerSmoke)

Compile-only package that protects public consumer-facing API shapes across the
three shipping products.

### [WrapperSmoke](./WrapperSmoke)

Compile-only package that protects wrapper-style integrations built on
future-candidate low-level execution hooks. These source shapes are not part of
the 4.0.0 stable public contract.

### [MacroUsage](./MacroUsage)

Compile-only package for the optional `InnoNetworkCodegen` product. It keeps
macro usage separate from the core consumer smoke so `InnoNetwork`-only users do
not pull `swift-syntax`.

## Getting Started

### Prerequisites

- Swift 6.2+
- Xcode 15.0+

### Installation

Add InnoNetwork to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/InnoSquadCorp/InnoNetwork.git", from: "4.0.0")
]
```

`4.0.0` is the latest public release. Pin a repository revision only when
validating unreleased changes.

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
    var contentType: ContentType { .formUrlEncoded }

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
} catch let error as NetworkError {
    switch error {
    case .statusCode(let response):
        print("HTTP Error: \(response.statusCode)")
    case .objectMapping(let decodingError, _):
        print("Decoding Error: \(decodingError)")
    default:
        print("Other Error: \(error)")
    }
}
```

### Download (InnoNetworkDownload)

```swift
import InnoNetworkDownload

let manager = DownloadManager.shared

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

- GitHub Issues: https://github.com/InnoSquad/InnoNetwork/issues
- Documentation: See individual example READMEs
