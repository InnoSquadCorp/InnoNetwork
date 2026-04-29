import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import InnoNetworkMacros

@Suite("InnoNetwork macro expansion")
struct MacroExpansionTests {
    private let macros: [String: Macro.Type] = [
        "APIDefinition": APIDefinitionMacro.self,
        "endpoint": EndpointMacro.self,
    ]

    @Test("APIDefinition macro derives protocol conformance")
    func apiDefinitionExpansion() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users/{id}")
            public struct GetUser {
                public let id: Int
                public typealias APIResponse = User
            }
            """,
            expandedSource:
                """
                public struct GetUser {
                    public let id: Int
                    public typealias APIResponse = User
                }

                extension GetUser: APIDefinition {
                    public typealias Parameter = EmptyParameter
                    public var method: HTTPMethod { .get }
                    public var path: String { "/users/\\(id)" }
                }
                """,
            macros: macros
        )
    }

    @Test("endpoint macro creates Endpoint builder expression")
    func endpointExpansion() {
        assertMacroExpansion(
            """
            let endpoint = #endpoint(.get, "/users/\\(id)", as: User.self)
            """,
            expandedSource:
                """
                let endpoint = Endpoint<EmptyResponse>(method: .get, path: "/users/\\(id)").decoding(User.self)
                """,
            macros: macros
        )
    }
}
