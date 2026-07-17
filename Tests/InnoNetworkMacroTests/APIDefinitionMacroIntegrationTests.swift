#if Macros
import Foundation
import InnoNetwork
import Testing

@Suite("APIDefinition macro integration")
struct APIDefinitionMacroIntegrationTests {
    @Test("empty GET preserves the explicit response contract and encodes path values")
    func emptyGet() {
        let endpoint = MacroGetUser(id: "a/b 100% ✓")

        #expect(endpoint.method == .get)
        #expect(endpoint.path == "/users/a%2Fb%20100%25%20%E2%9C%93")
        if case .some = endpoint.parameters {
            Issue.record("An endpoint without body or query must use EmptyParameter with nil parameters.")
        }
        #expect(endpoint.sessionAuthentication == .anonymous)
    }

    @Test("GET query maps to Parameter and parameters")
    func getQuery() {
        let query = MacroUserQuery(page: 2)
        let endpoint = MacroListUsers(query: query)

        #expect(endpoint.method == .get)
        #expect(endpoint.parameters == query)
        #expect(endpoint.sessionAuthentication == .optional)
    }

    @Test("POST body maps to Parameter and required auth")
    func postBody() {
        let body = MacroCreateUserBody(name: "Blob")
        let endpoint = MacroCreateUser(body: body)

        #expect(endpoint.method == .post)
        #expect(endpoint.path == "/users")
        #expect(endpoint.parameters == body)
        #expect(endpoint.sessionAuthentication == .required)
    }

    @Test("complete manual payload witnesses remain authoritative")
    func manualPayloadFallback() {
        let payload = MacroUserQuery(page: 3)
        let endpoint = MacroManualSearch(payload: payload)

        #expect(endpoint.parameters == payload)
        #expect(endpoint.path == "/users/search")
    }

    @Test("optional body and query aliases normalize nil as no payload")
    func optionalPayloadAliases() throws {
        if case .some = MacroOptionalCreateUser(body: nil).parameters {
            Issue.record("A nil body alias must map to no request payload.")
        }
        if case .some = MacroOptionalListUsers(query: nil).parameters {
            Issue.record("A nil query alias must map to no request payload.")
        }

        let body = MacroCreateUserBody(name: "Blob")
        let encodedParameter = try #require(MacroOptionalCreateUser(body: body).parameters)
        let data = try JSONEncoder().encode(encodedParameter)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object["name"] == "Blob")

        let query = MacroUserQuery(page: 4)
        let queryParameter = MacroOptionalListUsers(query: query).parameters.flatMap { $0 }
        #expect(queryParameter == query)
    }
}

private struct MacroUser: Decodable, Sendable {
    let id: Int
}

private struct MacroUserQuery: Codable, Equatable, Sendable {
    let page: Int
}

private struct MacroCreateUserBody: Codable, Equatable, Sendable {
    let name: String
}

private typealias MacroOptionalCreateUserBody = MacroCreateUserBody?
private typealias MacroOptionalUserQuery = MacroUserQuery?

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
private struct MacroGetUser {
    typealias APIResponse = MacroUser

    let id: String
}

@APIDefinition(method: HTTPMethod.get, path: "/users", auth: SessionAuthentication.optional)
private struct MacroListUsers {
    typealias APIResponse = [MacroUser]

    let query: MacroUserQuery
}

@APIDefinition(
    method: InnoNetwork.HTTPMethod.post,
    path: "/users",
    auth: InnoNetwork.SessionAuthentication.required
)
private struct MacroCreateUser {
    typealias APIResponse = MacroUser

    let body: MacroCreateUserBody
}

@APIDefinition(method: .get, path: "/users/search", auth: .anonymous)
private struct MacroManualSearch {
    typealias APIResponse = [MacroUser]
    typealias Parameter = MacroUserQuery

    let payload: MacroUserQuery

    var parameters: Parameter? { payload }
}

@APIDefinition(method: .post, path: "/users/optional", auth: .anonymous)
private struct MacroOptionalCreateUser {
    typealias APIResponse = MacroUser

    let body: MacroOptionalCreateUserBody
}

@APIDefinition(method: .get, path: "/users/optional", auth: .anonymous)
private struct MacroOptionalListUsers {
    typealias APIResponse = [MacroUser]

    let query: MacroOptionalUserQuery
}

#endif
