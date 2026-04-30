import Foundation
import InnoNetwork
import InnoNetworkTestSupport

private struct SmokeResponse: Codable, Sendable {
    let ok: Bool
}


private struct SmokeRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = SmokeResponse

    var method: HTTPMethod { .get }
    var path: String { "/smoke" }
}


let session = MockURLSession()
try session.setMockJSON(SmokeResponse(ok: true))

let client = DefaultNetworkClient(
    configuration: .safeDefaults(baseURL: URL(string: "https://api.example.com")!),
    session: session
)

private let response = try await client.request(SmokeRequest())
precondition(response.ok)
precondition(session.capturedRequest?.url?.absoluteString == "https://api.example.com/smoke")

print("TestSupportSmoke OK")
