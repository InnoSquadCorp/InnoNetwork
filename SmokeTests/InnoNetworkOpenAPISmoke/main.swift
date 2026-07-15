import Foundation
import InnoNetwork
import InnoNetworkOpenAPI

// MARK: - InnoNetworkOpenAPISmoke
//
// Integration smoke that exercises the `OpenAPIAdapter` end-to-end —
// it routes an `OpenAPIRestOperation` descriptor through `OpenAPIRequest`
// and dispatches it via `DefaultNetworkClient`. The live request is
// gated behind `INNONETWORK_RUN_INTEGRATION=1`; without the flag, the
// target verifies the adapter still composes and exits 0 so build CI
// stays unaffected.
//
// Compile-only mode (default): exercises the descriptor + adapter
// composition only. No URLSession traffic is generated.
//
// Live mode (`INNONETWORK_RUN_INTEGRATION=1`): issues a GET against a
// supplied JSON endpoint that returns an array of records and decodes
// the payload. Exit 1 on any transport or decoding failure.

private struct SmokeUser: Decodable, Sendable {
    let id: Int
    let name: String
}

private struct SmokeListUsers: OpenAPIRestOperation {
    typealias Response = [SmokeUser]

    var method: HTTPMethod { .get }
    var path: String { "/users" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
}

private let environment = ProcessInfo.processInfo.environment
private let runIntegration = environment["INNONETWORK_RUN_INTEGRATION"] == "1"
private let arguments = CommandLine.arguments

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    exit(1)
}

private let operation = SmokeListUsers()
private let request = OpenAPIRequest(operation)

precondition(request.method == .get)
precondition(request.path == "/users")
print("✓ adapter    OpenAPIRequest forwards method/path from operation")

guard runIntegration else {
    let note = """
        InnoNetworkOpenAPISmoke skipped live phase (INNONETWORK_RUN_INTEGRATION != 1).
        Set the flag and provide an explicit JSON base URL to exercise the
        OpenAPIAdapter end-to-end:

            INNONETWORK_RUN_INTEGRATION=1 swift run InnoNetworkOpenAPISmoke \\
                https://jsonplaceholder.typicode.com

        """
    FileHandle.standardOutput.write(Data(note.utf8))
    print("InnoNetworkOpenAPISmoke OK (compile-only)")
    exit(0)
}

guard
    arguments.count > 1,
    let baseURL = URL(string: arguments[1]),
    baseURL.scheme?.lowercased() == "https"
else {
    FileHandle.standardError.write(
        Data(
            "Usage: INNONETWORK_RUN_INTEGRATION=1 swift run InnoNetworkOpenAPISmoke [https://host]\n".utf8
        )
    )
    exit(2)
}

let configuration = NetworkConfiguration.safeDefaults(baseURL: baseURL)
let client = DefaultNetworkClient(configuration: configuration)

print("▶︎ GET \(baseURL.absoluteString)\(operation.path)")

do {
    let users: [SmokeUser] = try await client.request(request)
    guard !users.isEmpty else {
        fail("response decoded to an empty array")
    }
    print("✓ decoded    \(users.count) user(s); first id=\(users[0].id) name=\(users[0].name)")
} catch {
    fail("request failed: \(error)")
}

print("InnoNetworkOpenAPISmoke OK")
