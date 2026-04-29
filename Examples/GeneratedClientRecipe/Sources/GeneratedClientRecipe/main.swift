import Foundation
@_spi(GeneratedClientSupport) import InnoNetwork

private struct GeneratedUser: Decodable, Sendable {
    let id: Int
    let name: String
}

private struct GeneratedReport: Decodable, Sendable {
    let identifier: String
}

private enum GeneratedSDK {
    struct ListUsersQuery: Encodable, Sendable {
        let limit: Int
    }

    struct ListUsersOperation: Sendable {
        typealias Output = [GeneratedUser]

        let method: HTTPMethod = .get
        let path: String = "/v1/users"
        let parameters: ListUsersQuery?

        init(limit: Int) {
            self.parameters = ListUsersQuery(limit: limit)
        }
    }

    struct CreateReportBody: Encodable, Sendable {
        let includeDrafts: Bool
    }

    struct CreateReportOperation: Sendable {
        typealias Output = GeneratedReport

        let method: HTTPMethod = .post
        let path: String = "/v1/reports"
        let headers: HTTPHeaders = [
            .accept("application/json"),
            .contentType("application/json"),
        ]
        let body: CreateReportBody
    }
}

private protocol GeneratedRESTContract: Sendable {
    associatedtype Parameter: Encodable & Sendable
    associatedtype Output: Decodable & Sendable

    var parameters: Parameter? { get }
    var method: HTTPMethod { get }
    var path: String { get }
}

private protocol GeneratedExecutableContract: Sendable {
    associatedtype Output: Sendable

    var method: HTTPMethod { get }
    var path: String { get }
    var headers: HTTPHeaders { get }

    func makePayload() throws -> RequestPayload
    func decode(data: Data, response: Response) throws -> Output
}

extension GeneratedSDK.ListUsersOperation: GeneratedRESTContract {}

extension GeneratedSDK.CreateReportOperation: GeneratedExecutableContract {
    fileprivate func makePayload() throws -> RequestPayload {
        .data(try JSONEncoder().encode(body))
    }

    fileprivate func decode(data: Data, response: Response) throws -> Output {
        _ = response
        return try JSONDecoder().decode(Output.self, from: data)
    }
}

private struct GeneratedRESTRequest<Operation: GeneratedRESTContract>: APIDefinition {
    typealias Parameter = Operation.Parameter
    typealias APIResponse = Operation.Output

    let operation: Operation

    var parameters: Parameter? { operation.parameters }
    var method: HTTPMethod { operation.method }
    var path: String { operation.path }
}

private struct GeneratedExecutable<Operation: GeneratedExecutableContract>: SingleRequestExecutable {
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

private struct GeneratedClient: Sendable {
    let requestClient: any NetworkClient
    let lowLevelClient: any LowLevelNetworkClient

    func listUsers(limit: Int) async throws -> [GeneratedUser] {
        try await requestClient.request(
            GeneratedRESTRequest(operation: GeneratedSDK.ListUsersOperation(limit: limit))
        )
    }

    func createReport(includeDrafts: Bool) async throws -> GeneratedReport {
        try await lowLevelClient.perform(
            executable: GeneratedExecutable(
                operation: GeneratedSDK.CreateReportOperation(
                    body: .init(includeDrafts: includeDrafts)
                )
            )
        )
    }
}

@Sendable private func smokeGeneratedClient(_ client: GeneratedClient) async throws {
    let users = try await client.listUsers(limit: 20)
    let report = try await client.createReport(includeDrafts: true)
    _ = users
    _ = report
}

private let baseClient = DefaultNetworkClient(
    configuration: .safeDefaults(
        baseURL: URL(string: "https://api.example.com")!
    )
)
private let generatedClient = GeneratedClient(
    requestClient: baseClient,
    lowLevelClient: baseClient
)
_ = generatedClient
_ = smokeGeneratedClient

print("GeneratedClientRecipe OK")
