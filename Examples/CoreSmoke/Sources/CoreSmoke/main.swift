import Foundation
import InnoNetwork

private struct CoreUser: Decodable, Sendable {
    let id: Int
    let name: String
}

private struct CoreRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = CoreUser

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
}

let client = DefaultNetworkClient(
    configuration: .safeDefaults(
        baseURL: URL(string: "https://api.example.com")!
    )
)

_ = client
_ = CoreRequest()
_ = Endpoint.get("/users").query(["limit": 20]).decoding([CoreUser].self)
_ = NetworkConfiguration.advanced(baseURL: URL(string: "https://api.example.com")!) { builder in
    builder.retryPolicy = ExponentialBackoffRetryPolicy()
    builder.requestCoalescingPolicy = .getOnly
}

print("CoreSmoke OK")
