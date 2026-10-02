import Foundation
import InnoNetwork
import InnoNetworkTestSupport

// Accepted 6.0 source: helpers and policy witnesses are selected by Swift,
// independently of the macro's unconditional payload inference.
@APIDefinition(method: .get, path: "/health", auth: .anonymous)
private struct ConditionalHealth {
    typealias APIResponse = String
    #if DEBUG
    func diagnosticLabel() -> String { "debug" }
    var headers: HTTPHeaders { ["X-Configuration": "debug"] }
    #else
    func diagnosticLabel() -> String { "release" }
    var headers: HTTPHeaders { ["X-Configuration": "release"] }
    #endif
}

@APIDefinition(method: .post, path: "/manual", auth: .anonymous)
private struct ConditionalManualPayload {
    typealias APIResponse = String
    typealias Parameter = String
    var parameters: String? { body }
    #if DEBUG
    var body: String { "debug-body" }
    #else
    var body: String { "release-body" }
    #endif
}

// Compatibility fixture, NOT recommended endpoint design. 6.0 ignored this
// conditional body. 6.1 must warn, not silently change the request's wire shape.
@APIDefinition(method: .post, path: "/legacy", auth: .anonymous)
private struct ConditionalLegacyPayload {
    typealias APIResponse = String
    #if DEBUG
    let body: String = "not-inferred"
    #endif
}

// Compile-checked migration for the Provisionally Stable operation adapter.
private extension OperationNetworkClient where Base: NetworkClient {
    func startCompatible<Request: APIDefinition>(_ request: Request) -> NetworkOperation<Request.APIResponse> {
        start(request)
    }
}

func runMinorCompatibilitySmoke() async throws {
    let endpoint = ConditionalHealth()
    #if DEBUG
    let expectedConfiguration = "debug"
    #else
    let expectedConfiguration = "release"
    #endif
    precondition(endpoint.diagnosticLabel() == expectedConfiguration)
    precondition(endpoint.method == .get && endpoint.path == "/health")
    precondition(endpoint.sessionAuthentication == .anonymous)
    let noParameters: EmptyParameter? = endpoint.parameters
    precondition(noParameters == nil)

    let session = MockURLSession()
    session.setMockResponse(statusCode: 200, data: Data("\"ok\"".utf8))
    let client = DefaultNetworkClient(
        configuration: .safeDefaults(baseURL: URL(string: "https://example.com")!), session: session)
    let value = try await OperationNetworkClient(client: client).startCompatible(endpoint).value()
    precondition(value == "ok")
    _ = try await client.request(ConditionalManualPayload())
    let legacy = ConditionalLegacyPayload()
    let legacyParameters: EmptyParameter? = legacy.parameters
    precondition(legacyParameters == nil)
    _ = try await client.request(legacy)

    let requests = session.capturedRequestsInOrder
    precondition(requests.count == 3)
    precondition(requests[0].value(forHTTPHeaderField: "X-Configuration") == expectedConfiguration)
    let manualBody = try JSONDecoder().decode(String.self, from: requests[1].httpBody ?? Data())
    precondition(manualBody == expectedConfiguration + "-body")
    precondition(requests[2].httpBody == nil)
}
