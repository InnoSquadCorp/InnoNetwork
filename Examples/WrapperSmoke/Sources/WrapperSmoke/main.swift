import Foundation
@_spi(GeneratedClientSupport) import InnoNetwork

private struct WrappedUser: Decodable, Sendable {
    let id: Int
    let name: String
}

private protocol WrapperRequestContract: Sendable {
    associatedtype Output: Decodable & Sendable

    var method: HTTPMethod { get }
    var path: String { get }
    var headers: HTTPHeaders { get }
    var queryItems: [URLQueryItem] { get }
}

private struct WrappedUserRequest: WrapperRequestContract {
    typealias Output = WrappedUser

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
    var headers: HTTPHeaders { [.accept("application/json")] }
    var queryItems: [URLQueryItem] { [] }
}

private struct WrapperExecutable<Base: WrapperRequestContract>: SingleRequestExecutable {
    typealias APIResponse = Base.Output

    let base: Base

    var logger: NetworkLogger { NoOpNetworkLogger() }
    var requestInterceptors: [RequestInterceptor] { [] }
    var responseInterceptors: [ResponseInterceptor] { [] }
    var method: HTTPMethod { base.method }
    var path: String { base.path }
    var headers: HTTPHeaders { base.headers }

    func makePayload() throws -> RequestPayload {
        base.queryItems.isEmpty ? .none : .queryItems(base.queryItems)
    }

    func decode(data: Data, response: Response) throws -> Base.Output {
        _ = response
        return try JSONDecoder().decode(Base.Output.self, from: data)
    }
}

private struct WrapperClient: Sendable {
    let client: any LowLevelNetworkClient

    func send<Request: WrapperRequestContract>(_ request: Request) async throws -> Request.Output {
        try await client.perform(executable: WrapperExecutable(base: request))
    }
}

@Sendable private func smokeWrapperExecution(_ client: WrapperClient) async throws {
    let user: WrappedUser = try await client.send(WrappedUserRequest())
    _ = user
}

private let baseClient = DefaultNetworkClient(
    configuration: .safeDefaults(
        baseURL: URL(string: "https://api.example.com")!
    )
)
private let wrapperClient = WrapperClient(client: baseClient)
_ = wrapperClient
_ = smokeWrapperExecution

print("WrapperSmoke OK")
