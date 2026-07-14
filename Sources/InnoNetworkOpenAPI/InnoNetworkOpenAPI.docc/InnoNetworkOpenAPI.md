# ``InnoNetworkOpenAPI``

Connect generated or generated-style OpenAPI operations to InnoNetwork without
mixing code generation dependencies into the core product.

## Overview

`InnoNetworkOpenAPI` supports two integration directions:

- Wrap an ``OpenAPIRestOperation`` in ``OpenAPIRequest`` when the operation
  should use `DefaultNetworkClient` and its request execution pipeline.
- Give ``InnoNetworkClientTransport`` to a client produced by
  `swift-openapi-generator` when the generated client should remain the public
  entry point and dispatch through an application-owned `URLSession`.

The client transport carries URLSession-level behavior such as timeouts, cache
policy, cookies, and HTTP protocol configuration. It does not pass generated
requests through InnoNetwork interceptors, retry policy, cache policy, or trust
evaluation. Use ``OpenAPIRequest`` when those pipeline features are required.

```swift
import Foundation
import InnoNetwork
import InnoNetworkOpenAPI

struct Pet: Decodable, Sendable {
    let id: Int
    let name: String
}

struct ListPets: OpenAPIRestOperation {
    typealias Response = [Pet]

    let method: HTTPMethod = .get
    let path = "/pets"
}

let client = DefaultNetworkClient(
    configuration: .safeDefaults(
        baseURL: URL(string: "https://api.example.com")!
    )
)
let pets = try await client.request(OpenAPIRequest(ListPets()))
```

## Topics

### InnoNetwork request pipeline

- ``OpenAPIRestOperation``
- ``OpenAPIRequest``

### Generated client transport

- ``InnoNetworkClientTransport``
- ``InnoNetworkClientTransportError``
