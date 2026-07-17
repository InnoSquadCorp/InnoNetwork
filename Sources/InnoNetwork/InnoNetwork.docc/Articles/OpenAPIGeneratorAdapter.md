# Swift OpenAPI Generator Adapter

Use Swift OpenAPI Generator beside InnoNetwork without adding generator-specific
dependencies to the core runtime products.

## Companion path: wrap operations as `APIDefinition`

Prefer this path when the generated operation already exposes `Encodable`
input and `Decodable` output. The `InnoNetworkOpenAPI` companion product
contains the small wrapper surface while `InnoNetwork`, `InnoNetworkDownload`,
`InnoNetworkWebSocket`, and `InnoNetworkPersistentCache` remain free of
generator or HTTPTypes dependencies.

```swift
import InnoNetwork
import InnoNetworkOpenAPI

struct ListUsersOperation: OpenAPIRestOperation {
    typealias Response = [User]

    var method: HTTPMethod { .get }
    var path: String { "/users" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
}

let users = try await client.request(OpenAPIRequest(ListUsersOperation()))
```

Generated clients can keep their own public surface and delegate the transport
boundary to any ``NetworkClient``:

```swift
struct UsersGeneratedClient: Sendable {
    let networkClient: any NetworkClient

    func listUsers(_ operation: ListUsersOperation) async throws -> [User] {
        try await networkClient.request(OpenAPIRequest(operation))
    }
}
```

## Advanced path: opt into generated-client SPI

Use the SPI path only when a generated operation owns serialization or decoding
that does not fit `Encodable` / `Decodable`. The package must explicitly import
the SPI and pin a reviewed `main` revision while 5.0 remains unreleased because
this hook is not part of the draft public contract. Do not ship a moving branch
dependency in production; SPI remains outside SemVer guarantees even after a
tagged release.

```swift
import Foundation
@_spi(GeneratedClientSupport) import InnoNetwork

protocol OpenAPIExecutableOperation: Sendable {
    associatedtype Output: Sendable

    var method: HTTPMethod { get }
    var path: String { get }
    var headers: HTTPHeaders { get }
    var sessionAuthentication: SessionAuthentication { get }

    func makePayload() throws -> RequestPayload
    func decode(data: Data, response: Response) throws -> Output
}

struct OpenAPIExecutable<Operation: OpenAPIExecutableOperation>: SingleRequestExecutable {
    typealias APIResponse = Operation.Output

    let operation: Operation

    var method: HTTPMethod { operation.method }
    var path: String { operation.path }
    var headers: HTTPHeaders { operation.headers }
    var sessionAuthentication: SessionAuthentication { operation.sessionAuthentication }

    func makePayload() throws -> RequestPayload {
        try operation.makePayload()
    }

    func decode(data: Data, response: Response) throws -> Operation.Output {
        try operation.decode(data: data, response: response)
    }
}
```

The repository's `Examples/GeneratedClientRecipe` target is a compile-smoke
sample for this SPI import shape without tying InnoNetwork to a specific
OpenAPI generator version.

The preview generator writes `.anonymous` because it does not interpret
OpenAPI security schemes. Treat that value as a review marker, not as a
security decision made by the generator.

## Dependency boundary

`InnoNetworkOpenAPI` is intentionally thin: it adapts operation descriptors to
``APIDefinition`` and leaves generator-specific model, operation, and HTTPTypes
packages in the caller's target. Reserve the SPI hook for revision-pinned
wrappers that need custom serialization.
