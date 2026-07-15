# Generated Client Recipe

Adapt generated SDKs onto `InnoNetwork` without binding the repository to a
specific OpenAPI or RPC generator.

> Important: prefer the stable ``APIDefinition`` and
> ``RequestExecutionPolicy`` paths first. The low-level execution path remains
> SPI and is not part of the 5.0 stability promise.

## Choose the integration path

Use ``APIDefinition`` when generated operations already fit the library's
default transport model:

- request bodies are `Encodable`
- responses are `Decodable`
- query / body encoding can follow the built-in request policy

Generated SDKs that need transport-attempt behavior below interceptors can add
a public ``RequestExecutionPolicy`` through ``NetworkConfiguration``. Use the
SPI ``SingleRequestExecutable`` path only when the generated surface must stay
independent from ``APIDefinition`` or needs custom serialization that cannot be
represented as `Encodable`:

- custom serialization outside `Encodable`
- generator-owned request metadata and headers
- custom decoding or validation per operation

When a generator emits one concrete Swift type per fixed REST operation, it
can use the root macro without entering SPI:

```swift
import InnoNetwork

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
struct GeneratedGetUser {
    typealias APIResponse = User

    let id: Int
}
```

The generated struct remains the source of truth. The macro requires the
response type and auth choice to stay explicit, and derives only repetitive
protocol witnesses. A generic adapter whose method or path is dynamic should
use the hand-written conformance below instead.

## Path 1: Generated REST contract to `APIDefinition`

```swift
import InnoNetwork

protocol GeneratedRESTContract: Sendable {
    associatedtype Parameter: Encodable & Sendable
    associatedtype Output: Decodable & Sendable

    var parameters: Parameter? { get }
    var method: HTTPMethod { get }
    var path: String { get }
    var sessionAuthentication: SessionAuthentication { get }
}

struct GeneratedRESTRequest<Operation: GeneratedRESTContract>: APIDefinition {
    typealias Parameter = Operation.Parameter
    typealias APIResponse = Operation.Output

    let operation: Operation

    var parameters: Parameter? { operation.parameters }
    var method: HTTPMethod { operation.method }
    var path: String { operation.path }
    var sessionAuthentication: SessionAuthentication { operation.sessionAuthentication }
}
```

Stay on ``NetworkClient/request(_:)`` for this shape. It keeps the generated
type lightweight while reusing `InnoNetwork`'s default encoding, retry, trust,
and observability behavior.

## SPI path: Generated operation to `SingleRequestExecutable`

```swift
import Foundation
@_spi(GeneratedClientSupport) import InnoNetwork

protocol GeneratedExecutableContract: Sendable {
    associatedtype Output: Sendable

    var method: HTTPMethod { get }
    var path: String { get }
    var sessionAuthentication: SessionAuthentication { get }
    var headers: HTTPHeaders { get }

    func makePayload() throws -> RequestPayload
    func decode(data: Data, response: Response) throws -> Output
}

struct GeneratedExecutable<Operation: GeneratedExecutableContract>: SingleRequestExecutable {
    typealias APIResponse = Operation.Output

    let operation: Operation

    var logger: NetworkLogger { NoOpNetworkLogger() }
    var requestInterceptors: [RequestInterceptor] { [] }
    var responseInterceptors: [ResponseInterceptor] { [] }
    var method: HTTPMethod { operation.method }
    var path: String { operation.path }
    var sessionAuthentication: SessionAuthentication { operation.sessionAuthentication }
    var headers: HTTPHeaders { operation.headers }

    func makePayload() throws -> RequestPayload {
        try operation.makePayload()
    }

    func decode(data: Data, response: Response) throws -> Operation.Output {
        try operation.decode(data: data, response: response)
    }
}
```

Call this path only from a package that intentionally opts into
`@_spi(GeneratedClientSupport)` and pins current source. The low-level API can
change outside the default import contract.

> Important: the `@_spi(GeneratedClientSupport)` surface is governed by a
> dedicated compatibility contract documented in
> [`API_STABILITY.md` →
> "@_spi(GeneratedClientSupport) Compatibility Contract"](../../../../API_STABILITY.md#_spigeneratedclientsupport-compatibility-contract).
> SPI symbols may break in any minor release; pin to an exact InnoNetwork tag
> if you import them at all.

## Repository sample

The repository includes `Examples/GeneratedClientRecipe`, a compile-only sample
that demonstrates both the stable request path and the future-candidate wrapper
path:

- a generated REST-style operation adapted onto ``APIDefinition``
- a richer generated operation adapted onto SPI ``SingleRequestExecutable``

Use the `APIDefinition` and ``RequestExecutionPolicy`` portions as the 5.0
guidance. Treat the richer wrapper portion as revision-pinned SPI material.

Generated OpenAPI Runtime clients should use the optional
`InnoNetworkOpenAPI` companion product. Its `swift-http-types` dependency stays
at that adapter boundary; adopting the root `InnoNetwork` product does not
change the core public request, header, or response models to HTTPTypes.
