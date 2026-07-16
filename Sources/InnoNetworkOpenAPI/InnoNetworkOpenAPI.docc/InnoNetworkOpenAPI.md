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
HTTP method tokens remain case-sensitive: the URLSession-backed transport
throws ``InnoNetworkClientTransportError/unsupportedRequestMethod(_:)`` when
Foundation would rewrite a generated token instead of transmitting it exactly.
The transport also applies `DefaultRedirectPolicy` and URL admission to every
automatic redirect. Rejected hops throw
``InnoNetworkClientTransportError/redirectRejected`` without including the
target URL. Cross-origin hops strip original request headers and clear values
from `URLSessionConfiguration.httpAdditionalHeaders`. Use a default or ephemeral
URLSession; a background URLSession throws
``InnoNetworkClientTransportError/backgroundSessionUnsupported`` before dispatch
because Foundation does not expose its redirect decisions to the task delegate.

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
    let sessionAuthentication: SessionAuthentication = .anonymous
}

let client = DefaultNetworkClient(
    configuration: .safeDefaults(
        baseURL: URL(string: "https://api.example.com")!
    )
)
let pets = try await client.request(OpenAPIRequest(ListPets()))
```

Authentication is never inferred from an OpenAPI security scheme by this
adapter. Review every generated operation and replace `.anonymous` with
`.optional` or `.required` when the service contract calls for it.

The generated-client transport follows HTTP no-body semantics: it returns no
`HTTPBody` for HEAD, successful CONNECT `2xx`, informational `1xx`, `204`,
`205`, and `304` responses, even if the server supplies bytes.

## Topics

### InnoNetwork request pipeline

- ``OpenAPIRestOperation``
- ``OpenAPIRequest``

### Generated client transport

- ``InnoNetworkClientTransport``
- ``InnoNetworkClientTransportError``
