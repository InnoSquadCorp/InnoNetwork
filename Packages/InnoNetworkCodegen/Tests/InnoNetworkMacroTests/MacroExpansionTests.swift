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
            @APIDefinition(method: .get, path: "/users/{id}", auth: .public)
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
                    public var method: HTTPMethod {
                        .get
                    }
                    public var path: String {
                        "/users/\\(InnoNetwork.EndpointPathEncoding.percentEncodedSegment(id))"
                    }
                }
                """,
            macros: macros
        )
    }

    @Test("APIDefinition macro derives internal protocol conformance")
    func apiDefinitionInternalExpansion() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .post, path: "/users/{id}/avatar", auth: .public)
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
                    internal typealias Parameter = EmptyParameter
                    internal var method: HTTPMethod {
                        .post
                    }
                    internal var path: String {
                        "/users/\\(InnoNetwork.EndpointPathEncoding.percentEncodedSegment(id))/avatar"
                    }
                }
                """,
            macros: macros
        )
    }

    @Test("APIDefinition macro derives package protocol conformance")
    func apiDefinitionPackageExpansion() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .delete, path: "/users/{id}", auth: .public)
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
                    package var method: HTTPMethod {
                        .delete
                    }
                    package var path: String {
                        "/users/\\(InnoNetwork.EndpointPathEncoding.percentEncodedSegment(id))"
                    }
                }
                """,
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects unknown path placeholders")
    func apiDefinitionUnknownPlaceholderDiagnostic() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users/{missing}", auth: .public)
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
                    column: 36
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects optional path placeholders")
    func apiDefinitionOptionalPlaceholderDiagnostic() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users/{id}", auth: .public)
            public struct GetUser {
                public let id: Int?
                public typealias APIResponse = User
            }
            """,
            expandedSource:
                """
                public struct GetUser {
                    public let id: Int?
                    public typealias APIResponse = User
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@APIDefinition path placeholder {id} cannot reference an Optional stored property.",
                    line: 1,
                    column: 36
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects implicitly-unwrapped optional path placeholders")
    func apiDefinitionImplicitlyUnwrappedOptionalPlaceholderDiagnostic() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users/{id}", auth: .public)
            struct GetUser {
                let id: Int!
                typealias APIResponse = User
            }
            """,
            expandedSource:
                """
                struct GetUser {
                    let id: Int!
                    typealias APIResponse = User
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@APIDefinition path placeholder {id} cannot reference an Optional stored property.",
                    line: 1,
                    column: 36
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects Optional generic path placeholders")
    func apiDefinitionOptionalGenericPlaceholderDiagnostic() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users/{id}", auth: .public)
            struct GetUser {
                let id: Optional<Int>
                typealias APIResponse = User
            }
            """,
            expandedSource:
                """
                struct GetUser {
                    let id: Optional<Int>
                    typealias APIResponse = User
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@APIDefinition path placeholder {id} cannot reference an Optional stored property.",
                    line: 1,
                    column: 36
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects path placeholders bound to generic parameters")
    func apiDefinitionGenericParameterPlaceholderDiagnostic() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users/{id}", auth: .public)
            struct GetUser<T> {
                let id: T
                typealias APIResponse = User
            }
            """,
            expandedSource:
                """
                struct GetUser<T> {
                    let id: T
                    typealias APIResponse = User
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@APIDefinition path placeholder {id} cannot reference a generic parameter. Declare the property with a concrete `LosslessStringConvertible & Sendable` type.",
                    line: 1,
                    column: 36
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects path placeholders bound to opaque types")
    func apiDefinitionOpaqueTypePlaceholderDiagnostic() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users/{id}", auth: .public)
            struct GetUser {
                let id: some LosslessStringConvertible
                typealias APIResponse = User
            }
            """,
            expandedSource:
                """
                struct GetUser {
                    let id: some LosslessStringConvertible
                    typealias APIResponse = User
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@APIDefinition path placeholder {id} cannot reference an opaque (`some`) type. Declare the property with a concrete `LosslessStringConvertible & Sendable` type.",
                    line: 1,
                    column: 36
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro suggests FixIt converting interpolation to placeholder")
    func apiDefinitionInterpolationFixIt() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users/\\(id)", auth: .public)
            struct GetUser {
                let id: Int
                typealias APIResponse = User
            }
            """,
            expandedSource:
                """
                struct GetUser {
                    let id: Int
                    typealias APIResponse = User
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@APIDefinition path: does not support string interpolation.",
                    line: 1,
                    column: 44,
                    fixIts: [
                        FixItSpec(
                            message: "Replace string interpolation with '{id}' path placeholder."
                        )
                    ]
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro omits FixIt for non-trivial interpolation")
    func apiDefinitionNoFixItForComplexInterpolation() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users/\\(user.id)", auth: .public)
            struct GetUser {
                let user: User
                typealias APIResponse = User
            }
            """,
            expandedSource:
                """
                struct GetUser {
                    let user: User
                    typealias APIResponse = User
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@APIDefinition path: does not support string interpolation.",
                    line: 1,
                    column: 44,
                    fixIts: []
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro derives an explicit GET query payload")
    func apiDefinitionQueryExpansion() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users", auth: .public)
            struct ListUsers {
                typealias APIResponse = [User]
                let query: ListUsersQuery
            }
            """,
            expandedSource:
                """
                struct ListUsers {
                    typealias APIResponse = [User]
                    let query: ListUsersQuery
                }

                extension ListUsers: APIDefinition {
                    internal typealias Parameter = ListUsersQuery
                    internal var parameters: Parameter? {
                        query
                    }
                    internal var method: HTTPMethod {
                        .get
                    }
                    internal var path: String {
                        "/users"
                    }
                }
                """,
            macros: macros
        )
    }

    @Test("APIDefinition macro derives a required-auth POST body")
    func apiDefinitionBodyAndAuthExpansion() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .post, path: "/users", auth: .required)
            struct CreateUser {
                typealias APIResponse = User
                let body: CreateUserRequest
            }
            """,
            expandedSource:
                """
                struct CreateUser {
                    typealias APIResponse = User
                    let body: CreateUserRequest
                }

                extension CreateUser: APIDefinition {
                    internal typealias Parameter = CreateUserRequest
                    internal var parameters: Parameter? {
                        body
                    }
                    internal typealias Auth = AuthRequiredScope
                    internal var method: HTTPMethod {
                        .post
                    }
                    internal var path: String {
                        "/users"
                    }
                }
                """,
            macros: macros
        )
    }

    @Test("APIDefinition macro preserves an explicit Parameter contract")
    func apiDefinitionManualParameterExpansion() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .post, path: "/users", auth: .public)
            struct CreateUser {
                typealias APIResponse = User
                typealias Parameter = CreateUserRequest
                let parameters: Parameter?
                var transport: TransportPolicy<User> { .json() }
            }
            """,
            expandedSource:
                """
                struct CreateUser {
                    typealias APIResponse = User
                    typealias Parameter = CreateUserRequest
                    let parameters: Parameter?
                    var transport: TransportPolicy<User> { .json() }
                }

                extension CreateUser: APIDefinition {
                    internal var method: HTTPMethod {
                        .post
                    }
                    internal var path: String {
                        "/users"
                    }
                }
                """,
            macros: macros
        )
    }

    @Test("endpoint macro creates EndpointBuilder expression")
    func endpointExpansion() {
        assertMacroExpansion(
            """
            let endpoint = #endpoint(.get, "/users/\\(id)", as: User.self)
            """,
            expandedSource:
                """
                let endpoint = EndpointBuilder<EmptyResponse, PublicAuthScope>(method: .get, path: "/users/\\(id)").decoding(User.self)
                """,
            macros: macros
        )
    }

    @Test("endpoint macro propagates AuthRequiredScope when scope: is provided")
    func endpointAuthRequiredScopeExpansion() {
        assertMacroExpansion(
            """
            let endpoint = #endpoint(.get, "/me", as: User.self, scope: AuthRequiredScope.self)
            """,
            expandedSource:
                """
                let endpoint = EndpointBuilder<EmptyResponse, AuthRequiredScope>(method: .get, path: "/me").decoding(User.self)
                """,
            macros: macros
        )
    }

    @Test("endpoint macro accepts an explicit PublicAuthScope via scope:")
    func endpointExplicitPublicAuthScopeExpansion() {
        assertMacroExpansion(
            """
            let endpoint = #endpoint(.get, "/health", as: Health.self, scope: PublicAuthScope.self)
            """,
            expandedSource:
                """
                let endpoint = EndpointBuilder<EmptyResponse, PublicAuthScope>(method: .get, path: "/health").decoding(Health.self)
                """,
            macros: macros
        )
    }

    @Test("endpoint macro requires the scope label on the four-argument form")
    func endpointMacroRejectsUnlabeledFourthArgument() {
        assertMacroExpansion(
            """
            let endpoint = #endpoint(.get, "/me", as: User.self, AuthRequiredScope.self)
            """,
            expandedSource:
                """
                let endpoint = #endpoint(.get, "/me", as: User.self, AuthRequiredScope.self)
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "#endpoint fourth argument must be labeled scope:.",
                    line: 1,
                    column: 54
                )
            ],
            macros: macros
        )
    }

    @Test("endpoint macro rejects a non-metatype scope argument")
    func endpointMacroRejectsNonMetatypeScope() {
        assertMacroExpansion(
            """
            let endpoint = #endpoint(.get, "/me", as: User.self, scope: AuthRequiredScope())
            """,
            expandedSource:
                """
                let endpoint = #endpoint(.get, "/me", as: User.self, scope: AuthRequiredScope())
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "#endpoint scope: argument must be a metatype expression (e.g. AuthRequiredScope.self).",
                    line: 1,
                    column: 54
                )
            ],
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
                    column: 42
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
                    column: 26
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
                    column: 32
                )
            ],
            macros: macros
        )
    }
}
