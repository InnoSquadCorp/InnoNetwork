import Foundation
import InnoNetwork
import InnoNetworkOpenAPI
import InnoNetworkTestSupport

struct User: Codable, Equatable, Sendable {
    let id: Int
    let name: String
}

struct ListUsersQuery: Codable, Equatable, Sendable {
    let page: Int
    let includeArchived: Bool
}

struct ListUsers: OpenAPIRestOperation {
    typealias Parameters = ListUsersQuery
    typealias Response = [User]

    let parameters: ListUsersQuery?

    var method: HTTPMethod { .get }
    var path: String { "/users" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
}

enum SmokeFailure: Error {
    case invalidBaseURL
    case invalidRequest
}

guard let baseURL = URL(string: "https://api.example.com/v1") else {
    throw SmokeFailure.invalidBaseURL
}

let expectedUsers = [
    User(id: 42, name: "Blob"),
    User(id: 43, name: "Ada"),
]
let session = MockURLSession()
session.setScriptedResponses([
    .http(
        statusCode: 200,
        data: try JSONEncoder().encode(expectedUsers),
        headers: ["Content-Type": "application/json"],
        url: baseURL
    )
])

let client = DefaultNetworkClient(
    configuration: .safeDefaults(baseURL: baseURL),
    session: session
)
let users: [User] = try await client.request(
    OpenAPIRequest(
        ListUsers(
            parameters: ListUsersQuery(page: 2, includeArchived: true)
        )
    )
)

precondition(users == expectedUsers)
guard
    session.capturedRequestsInOrder.count == 1,
    let request = session.capturedRequestsInOrder.first,
    let url = request.url,
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
    let queryItems = components.queryItems
else {
    throw SmokeFailure.invalidRequest
}

precondition(request.httpMethod == "GET")
precondition(components.percentEncodedPath == "/v1/users")
precondition(queryItems.contains(URLQueryItem(name: "page", value: "2")))
precondition(queryItems.contains(URLQueryItem(name: "includeArchived", value: "true")))
precondition(request.value(forHTTPHeaderField: "Authorization") == nil)

print("OpenAPIAdopterSmoke OK")
