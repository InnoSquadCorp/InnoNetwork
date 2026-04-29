# Swift OpenAPI Generator Adapter

Use Swift OpenAPI Generator beside InnoNetwork without adding generator-specific
dependencies to this package.

## Stable path: wrap operations as `APIDefinition`

Prefer this path when the generated operation already exposes `Encodable`
input and `Decodable` output. The wrapper stays on the 4.0.0 stable API
contract because it only depends on ``APIDefinition`` and
``NetworkClient/request(_:)``.

```swift
import InnoNetwork

protocol OpenAPIRestOperation: Sendable {
    associatedtype Input: Encodable & Sendable
    associatedtype Output: Decodable & Sendable

    var method: HTTPMethod { get }
    var path: String { get }
    var input: Input? { get }
}

struct OpenAPIRequest<Operation: OpenAPIRestOperation>: APIDefinition {
    typealias Parameter = Operation.Input
    typealias APIResponse = Operation.Output

    let operation: Operation

    var method: HTTPMethod { operation.method }
    var path: String { operation.path }
    var parameters: Parameter? { operation.input }
}
```

Generated clients can keep their own public surface and delegate the transport
boundary to any ``NetworkClient``:

```swift
struct UsersGeneratedClient: Sendable {
    let networkClient: any NetworkClient

    func listUsers(_ operation: ListUsersOperation) async throws -> [User] {
        try await networkClient.request(OpenAPIRequest(operation: operation))
    }
}
```

## Advanced path: opt into generated-client SPI

Use the SPI path only when a generated operation owns serialization or decoding
that does not fit `Encodable` / `Decodable`. The package must explicitly import
the SPI and pin a revision because this hook is not part of the default 4.0.0
stable contract.

```swift
import Foundation
@_spi(GeneratedClientSupport) import InnoNetwork

protocol OpenAPIExecutableOperation: Sendable {
    associatedtype Output: Sendable

    var method: HTTPMethod { get }
    var path: String { get }
    var headers: HTTPHeaders { get }

    func makePayload() throws -> RequestPayload
    func decode(data: Data, response: Response) throws -> Output
}

struct OpenAPIExecutable<Operation: OpenAPIExecutableOperation>: SingleRequestExecutable {
    typealias APIResponse = Operation.Output

    let operation: Operation

    var logger: NetworkLogger { NoOpNetworkLogger() }
    var requestInterceptors: [RequestInterceptor] { [] }
    var responseInterceptors: [ResponseInterceptor] { [] }
    var method: HTTPMethod { operation.method }
    var path: String { operation.path }
    var headers: HTTPHeaders { operation.headers }

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
