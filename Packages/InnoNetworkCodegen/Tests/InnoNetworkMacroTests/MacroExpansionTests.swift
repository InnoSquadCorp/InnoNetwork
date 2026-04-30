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
                    public var path: String { "/users/\\(EndpointPathEncoding.percentEncodedSegment(id))" }
                }
                """,
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects unknown path placeholders")
    func apiDefinitionUnknownPlaceholderDiagnostic() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users/{missing}")
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
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@APIDefinition path placeholder {missing} must match a stored property.",
                    line: 1,
                    column: 1
                )
            ],
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

    @Test("endpoint macro requires the as label")
    func endpointMissingAsDiagnostic() {
        assertMacroExpansion(
            """
            let endpoint = #endpoint(.get, "/users", User.self)
            """,
            expandedSource:
                """
                let endpoint = #endpoint(.get, "/users", User.self)
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "#endpoint third argument must be labeled as:.",
                    line: 1,
                    column: 16
                )
            ],
            macros: macros
        )
    }

    @Test("endpoint macro rejects a labeled method argument")
    func endpointMacroRejectsLabeledMethodArgument() {
        assertMacroExpansion(
            """
            let endpoint = #endpoint(method: .get, "/users", as: User.self)
            """,
            expandedSource:
                """
                let endpoint = #endpoint(method: .get, "/users", as: User.self)
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "#endpoint first argument (method) must be unlabeled.",
                    line: 1,
                    column: 16
                )
            ],
            macros: macros
        )
    }

    @Test("endpoint macro rejects a labeled path argument")
    func endpointMacroRejectsLabeledPathArgument() {
        assertMacroExpansion(
            """
            let endpoint = #endpoint(.get, path: "/users", as: User.self)
            """,
            expandedSource:
                """
                let endpoint = #endpoint(.get, path: "/users", as: User.self)
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "#endpoint second argument (path) must be unlabeled.",
                    line: 1,
                    column: 16
                )
            ],
            macros: macros
        )
    }
}
