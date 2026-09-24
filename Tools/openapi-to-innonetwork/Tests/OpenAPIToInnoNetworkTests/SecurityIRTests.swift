import Foundation
import Testing

@testable import openapi_to_innonetwork

@Suite("Non-secret security IR")
struct SecurityIRTests {
    private let bearer = SecurityScheme(type: "http", scheme: "bearer")
    private let key = SecurityScheme(type: "apiKey", name: "X-Access", in: "header")

    @Test("AND is atomic metadata, OR order is preserved, members are deterministic")
    func alternatives() throws {
        let ir = try SecurityIR(
            requirements: [["session": [], "key": []], ["other": []], [:]],
            schemes: ["session": bearer, "key": key, "other": key])
        #expect(ir.alternatives.count == 3)
        #expect(ir.alternatives[0].map(\.schemeID) == ["key", "session"])
        #expect(ir.alternatives[1].map(\.schemeID) == ["other"])
        #expect(ir.alternatives[2].isEmpty)
        #expect(throws: GenerationError.self) { try ir.legacySessionAuthentication() }
        #expect(
            ir
                == (try SecurityIR(
                    requirements: [["key": [], "session": []], ["other": []], [:]],
                    schemes: ["key": key, "other": key, "session": bearer])))
    }

    @Test("absence, explicit removal and anonymous alternatives do not collapse in IR")
    func anonymous() throws {
        #expect(try SecurityIR(requirements: nil, schemes: [:]).alternatives.isEmpty)
        #expect(try SecurityIR(requirements: [], schemes: [:]).alternatives.isEmpty)
        #expect(try SecurityIR(requirements: [[:]], schemes: [:]).alternatives == [[]])
        #expect(
            try SecurityIR(requirements: [[:], ["a": []]], schemes: ["a": bearer])
                .legacySessionAuthentication() == "optional")
    }

    @Test("legacy bearer keeps one identity and refuses distinct bearer OR")
    func bearerIdentities() throws {
        #expect(
            try SecurityIR(requirements: [["a": []]], schemes: ["a": bearer])
                .legacySessionAuthentication() == "required")
        #expect(throws: GenerationError.self) {
            try SecurityIR(requirements: [["a": []], ["b": []]], schemes: ["a": bearer, "b": bearer])
                .legacySessionAuthentication()
        }
    }

    @Test("API key placement is retained without moving it to a header", arguments: ["header", "query", "cookie"])
    func placement(_ location: String) throws {
        let scheme = SecurityScheme(type: "apiKey", name: "credential", in: location)
        let ir = try SecurityIR(requirements: [["key": []]], schemes: ["key": scheme])
        let requirement = try #require(ir.alternatives.first?.first)
        #expect(requirement.wireSlot == "\(location):credential")
    }

    @Test("header slots collide case-insensitively; query names remain case-sensitive")
    func slots() throws {
        #expect(throws: GenerationError.self) {
            try SecurityIR(
                requirements: [["a": [], "b": []]],
                schemes: [
                    "a": key, "b": SecurityScheme(type: "apiKey", name: "x-access", in: "header"),
                ])
        }
        #expect(throws: GenerationError.self) {
            try SecurityIR(requirements: [["a": [], "b": []]], schemes: ["a": bearer, "b": bearer])
        }
        #expect(throws: GenerationError.self) {
            try SecurityIR(
                requirements: [["a": [], "b": []]],
                schemes: [
                    "a": SecurityScheme(type: "apiKey", name: "Cookie", in: "header"),
                    "b": SecurityScheme(type: "apiKey", name: "session", in: "cookie"),
                ])
        }
        let valid = try SecurityIR(
            requirements: [["a": [], "b": []]],
            schemes: [
                "a": SecurityScheme(type: "apiKey", name: "key", in: "query"),
                "b": SecurityScheme(type: "apiKey", name: "KEY", in: "query"),
            ])
        #expect(valid.alternatives[0].count == 2)
    }

    @Test("OAuth scopes retain exact case and decode real flow metadata")
    func oauthScopes() throws {
        let scheme = try JSONDecoder().decode(
            SecurityScheme.self,
            from: Data(
                #"""
                {"type":"oauth2","flows":{"authorizationCode":{"authorizationUrl":"https://id.example/authorize",
                "tokenUrl":"https://id.example/token","scopes":{"Read":"Read","write":"Write"}}}}
                """#.utf8))
        let ir = try SecurityIR(requirements: [["oauth": ["write", "Read"]]], schemes: ["oauth": scheme])
        #expect(ir.alternatives[0][0].scopes == ["Read", "write"])
        #expect(ir.alternatives[0][0].kind == .oauth2)
        #expect(throws: GenerationError.self) {
            try SecurityIR(requirements: [["oauth": ["read"]]], schemes: ["oauth": scheme])
        }
        #expect(throws: GenerationError.self) {
            try SecurityIR(requirements: [["oauth": ["Read", "Read"]]], schemes: ["oauth": scheme])
        }
    }

    @Test(
        "malformed or unsupported schemes cannot silently drop requirements",
        arguments: [
            SecurityScheme(type: "http", scheme: "basic"),
            SecurityScheme(type: "openIdConnect"),
            SecurityScheme(type: "apiKey", name: "Host", in: "header"),
            SecurityScheme(type: "apiKey", name: "X\r\nInjected", in: "header"),
            SecurityScheme(type: "apiKey", name: "", in: "query"),
            SecurityScheme(type: "apiKey", name: "key", in: "path"),
            SecurityScheme(type: "oauth2"),
        ])
    func invalidSchemes(_ scheme: SecurityScheme) {
        #expect(throws: GenerationError.self) { try SecurityIR(requirements: [["a": []]], schemes: ["a": scheme]) }
    }

    @Test("OAuth flows fail closed on unsupported flow, missing endpoint, insecure URL or malformed scope")
    func invalidFlows() {
        let flows: [[String: OAuthFlow]] = [
            ["unknown": OAuthFlow(tokenUrl: "https://id.example/token", scopes: [:])],
            ["authorizationCode": OAuthFlow(authorizationUrl: "https://id.example/auth", scopes: [:])],
            ["clientCredentials": OAuthFlow(tokenUrl: "http://id.example/token", scopes: [:])],
            ["clientCredentials": OAuthFlow(tokenUrl: "https://u:p@id.example/token", scopes: [:])],
            ["clientCredentials": OAuthFlow(tokenUrl: "https://id.example/token#fragment", scopes: [:])],
            ["clientCredentials": OAuthFlow(tokenUrl: "https://id.example/token", scopes: ["read write": "invalid"])],
        ]
        for flow in flows {
            #expect(throws: GenerationError.self) {
                try SecurityIR(requirements: [["a": []]], schemes: ["a": SecurityScheme(type: "oauth2", flows: flow)])
            }
        }
    }

    @Test("resource ceilings and non-OAuth scope restrictions")
    func limits() {
        #expect(throws: GenerationError.self) {
            try SecurityIR(requirements: Array(repeating: [:], count: 33), schemes: [:])
        }
        #expect(throws: GenerationError.self) { try SecurityIR(requirements: [["missing": []]], schemes: [:]) }
        #expect(throws: GenerationError.self) { try SecurityIR(requirements: [["a": ["read"]]], schemes: ["a": key]) }
        #expect(throws: GenerationError.self) {
            try SecurityIR(requirements: [["a": ["read"]]], schemes: ["a": bearer])
        }
        let oversized = Dictionary(uniqueKeysWithValues: (0..<17).map { ("s\($0)", [String]()) })
        #expect(throws: GenerationError.self) { try SecurityIR(requirements: [oversized], schemes: [:]) }
    }
}
