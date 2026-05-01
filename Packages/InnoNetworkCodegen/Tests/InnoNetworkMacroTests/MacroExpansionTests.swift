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

    @Test("APIDefinition macro derives public protocol conformance")
    func apiDefinitionPublicExpansion() {
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
                    public var path: String { "/users/\\(InnoNetwork.EndpointPathEncoding.percentEncodedSegment(id))" }
                }
                """,
            macros: macros
        )
    }

    @Test("APIDefinition macro derives internal protocol conformance")
    func apiDefinitionInternalExpansion() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .post, path: "/users/{id}/avatar")
            struct UpdateAvatar {
                let id: Int
                typealias APIResponse = Avatar
            }
            """,
            expandedSource:
                """
                struct UpdateAvatar {
                    let id: Int
                    typealias APIResponse = Avatar
                }

                extension UpdateAvatar: APIDefinition {
                    typealias Parameter = EmptyParameter
                    var method: HTTPMethod { .post }
                    var path: String { "/users/\\(InnoNetwork.EndpointPathEncoding.percentEncodedSegment(id))/avatar" }
                }
                """,
            macros: macros
        )
    }

    @Test("APIDefinition macro derives package protocol conformance")
    func apiDefinitionPackageExpansion() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .delete, path: "/users/{id}")
            package struct DeleteUser {
                package let id: Int
                package typealias APIResponse = EmptyResponse
            }
            """,
            expandedSource:
                """
                package struct DeleteUser {
                    package let id: Int
                    package typealias APIResponse = EmptyResponse
                }

                extension DeleteUser: APIDefinition {
                    package typealias Parameter = EmptyParameter
                    package var method: HTTPMethod { .delete }
                    package var path: String { "/users/\\(InnoNetwork.EndpointPathEncoding.percentEncodedSegment(id))" }
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
