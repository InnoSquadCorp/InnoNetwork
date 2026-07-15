#if Macros
import Foundation
import InnoNetwork
import InnoNetworkTestSupport
import Testing

@Suite("APIDefinition macro to DefaultNetworkClient E2E")
struct APIDefinitionMacroClientE2ETests {
    @Test("GET expands a path placeholder, encodes query values, and decodes the response")
    func getPlaceholderQueryAndDecode() async throws {
        let session = MockURLSession()
        let expected = MacroClientUser(id: 42, name: "Blob")
        try session.setMockJSON(expected)
        let client = DefaultNetworkClient(
            configuration: makeMacroClientTestConfiguration(),
            session: session
        )

        let response = try await client.request(
            MacroClientGetUser(
                id: "team/a",
                query: MacroClientUserQuery(page: 2, includeArchived: true)
            )
        )

        #expect(response == expected)
        let request = try #require(session.capturedRequest)
        #expect(request.httpMethod == "GET")
        let components = try #require(
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        )
        #expect(components.percentEncodedPath == "/v1/users/team%2Fa")
        let queryItems = try #require(components.queryItems)
        #expect(queryItems.contains(URLQueryItem(name: "page", value: "2")))
        #expect(queryItems.contains(URLQueryItem(name: "includeArchived", value: "true")))
        #expect(request.httpBody == nil)
    }

    @Test("POST encodes JSON method, body, and content type, then decodes the response")
    func postJSONAndDecode() async throws {
        let session = MockURLSession()
        let expected = MacroClientUser(id: 43, name: "Ada")
        try session.setMockJSON(expected)
        let client = DefaultNetworkClient(
            configuration: makeMacroClientTestConfiguration(),
            session: session
        )
        let body = MacroClientCreateUserBody(name: "Ada", role: "admin")

        let response = try await client.request(MacroClientCreateUser(body: body))

        #expect(response == expected)
        let request = try #require(session.capturedRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.example.com/v1/users")
        #expect(
            request.value(forHTTPHeaderField: "Content-Type")
                == "application/json; charset=UTF-8"
        )
        let requestBody = try #require(request.httpBody)
        #expect(try JSONDecoder().decode(MacroClientCreateUserBody.self, from: requestBody) == body)
    }

    @Test("required auth without a refresh policy fails before transport")
    func requiredAuthWithoutPolicyFailsBeforeTransport() async throws {
        let session = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: makeMacroClientTestConfiguration(),
            session: session
        )

        do {
            _ = try await client.request(MacroClientRequiredUser(id: 42))
            Issue.record("A required-auth macro endpoint must reject a missing refresh policy.")
        } catch let error {
            guard case .configuration(reason: .invalidRequest(let message)) = error else {
                Issue.record("Expected a configuration error, got \(error).")
                return
            }
            #expect(message.contains("refreshTokenPolicy"))
        }

        #expect(session.capturedRequestsInOrder.isEmpty)
    }

    @Test("required auth proactively refreshes a missing token before its only transport attempt")
    func requiredAuthProactivelyRefreshesBeforeTransport() async throws {
        let session = MockURLSession()
        let expected = MacroClientUser(id: 42, name: "Authenticated")
        try session.setMockJSON(expected)
        let trace = MacroClientAuthTrace()
        let policy = RefreshTokenPolicy(
            currentToken: { await trace.readCurrentToken() },
            refreshToken: { await trace.refreshToken() }
        )
        let client = DefaultNetworkClient(
            configuration: .advanced(
                baseURL: URL(string: "https://api.example.com/v1")!,
                resilience: ResiliencePack(
                    bodyBuffering: .buffered(maxBytes: 5 * 1024 * 1024)
                ),
                auth: AuthPack(refreshToken: policy)
            ),
            session: session
        )

        let response = try await client.request(MacroClientRequiredUser(id: 42))

        #expect(response == expected)
        #expect(await trace.snapshot() == ["current-token:nil", "refresh-token:fresh-token"])
        let requests = session.capturedRequestsInOrder
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
    }
}

private func makeMacroClientTestConfiguration() -> NetworkConfiguration {
    .advanced(
        baseURL: URL(string: "https://api.example.com/v1")!,
        resilience: ResiliencePack(
            bodyBuffering: .buffered(maxBytes: 5 * 1024 * 1024)
        )
    )
}

private struct MacroClientUser: Codable, Equatable, Sendable {
    let id: Int
    let name: String
}

private struct MacroClientUserQuery: Codable, Equatable, Sendable {
    let page: Int
    let includeArchived: Bool
}

private struct MacroClientCreateUserBody: Codable, Equatable, Sendable {
    let name: String
    let role: String
}

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
private struct MacroClientGetUser {
    typealias APIResponse = MacroClientUser

    let id: String
    let query: MacroClientUserQuery
}

@APIDefinition(method: .post, path: "/users", auth: .anonymous)
private struct MacroClientCreateUser {
    typealias APIResponse = MacroClientUser

    let body: MacroClientCreateUserBody
}

@APIDefinition(method: .get, path: "/secure/users/{id}", auth: .required)
private struct MacroClientRequiredUser {
    typealias APIResponse = MacroClientUser

    let id: Int
}

private actor MacroClientAuthTrace {
    private var events: [String] = []

    func readCurrentToken() -> String? {
        events.append("current-token:nil")
        return nil
    }

    func refreshToken() -> String {
        events.append("refresh-token:fresh-token")
        return "fresh-token"
    }

    func snapshot() -> [String] {
        events
    }
}
#endif
