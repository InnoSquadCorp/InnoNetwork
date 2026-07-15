#if Macros
import SwiftDiagnostics
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import InnoNetworkMacros

@Suite("InnoNetwork macro expansion")
struct MacroExpansionTests {
    private let macros: [String: Macro.Type] = [
        "APIDefinition": APIDefinitionMacro.self
    ]

    @Test("APIDefinition macro derives public protocol conformance")
    func apiDefinitionPublicExpansion() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
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

                extension GetUser: InnoNetwork.APIDefinition {
                    public typealias Parameter = InnoNetwork.EmptyParameter
                    public var sessionAuthentication: InnoNetwork.SessionAuthentication {
                        .anonymous
                    }
                    public var method: InnoNetwork.HTTPMethod {
                        .get
                    }
                    public var path: Swift.String {
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
            @APIDefinition(method: .post, path: "/users/{id}/avatar", auth: .anonymous)
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

                extension UpdateAvatar: InnoNetwork.APIDefinition {
                    internal typealias Parameter = InnoNetwork.EmptyParameter
                    internal var sessionAuthentication: InnoNetwork.SessionAuthentication {
                        .anonymous
                    }
                    internal var method: InnoNetwork.HTTPMethod {
                        .post
                    }
                    internal var path: Swift.String {
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
            @APIDefinition(method: .delete, path: "/users/{id}", auth: .anonymous)
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

                extension DeleteUser: InnoNetwork.APIDefinition {
                    package typealias Parameter = InnoNetwork.EmptyParameter
                    package var sessionAuthentication: InnoNetwork.SessionAuthentication {
                        .anonymous
                    }
                    package var method: InnoNetwork.HTTPMethod {
                        .delete
                    }
                    package var path: Swift.String {
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
            @APIDefinition(method: .get, path: "/users/{missing}", auth: .anonymous)
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
            @APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
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
            @APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
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
            @APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
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
            @APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
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
            @APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
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
            @APIDefinition(method: .get, path: "/users/\\(id)", auth: .anonymous)
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
            @APIDefinition(method: .get, path: "/users/\\(user.id)", auth: .anonymous)
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
            @APIDefinition(method: .get, path: "/users", auth: .anonymous)
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

                extension ListUsers: InnoNetwork.APIDefinition {
                    internal typealias Parameter = ListUsersQuery
                    internal var parameters: Parameter? {
                        func normalized<Value>(_ value: Value) -> Value? {
                            .some(value)
                        }
                        func normalized<Value>(_ value: Value?) -> Value?? {
                            guard let value else {
                                return nil
                            }
                            return .some(.some(value))
                        }
                        return normalized(query)
                    }
                    internal var sessionAuthentication: InnoNetwork.SessionAuthentication {
                        .anonymous
                    }
                    internal var method: InnoNetwork.HTTPMethod {
                        .get
                    }
                    internal var path: Swift.String {
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

                extension CreateUser: InnoNetwork.APIDefinition {
                    internal typealias Parameter = CreateUserRequest
                    internal var parameters: Parameter? {
                        func normalized<Value>(_ value: Value) -> Value? {
                            .some(value)
                        }
                        func normalized<Value>(_ value: Value?) -> Value?? {
                            guard let value else {
                                return nil
                            }
                            return .some(.some(value))
                        }
                        return normalized(body)
                    }
                    internal var sessionAuthentication: InnoNetwork.SessionAuthentication {
                        .required
                    }
                    internal var method: InnoNetwork.HTTPMethod {
                        .post
                    }
                    internal var path: Swift.String {
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
            @APIDefinition(method: .post, path: "/users", auth: .anonymous)
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

                extension CreateUser: InnoNetwork.APIDefinition {
                    internal var sessionAuthentication: InnoNetwork.SessionAuthentication {
                        .anonymous
                    }
                    internal var method: InnoNetwork.HTTPMethod {
                        .post
                    }
                    internal var path: Swift.String {
                        "/users"
                    }
                }
                """,
            macros: macros
        )
    }

    @Test("APIDefinition macro requires a struct value")
    func apiDefinitionRejectsClass() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users", auth: .anonymous)
            final class GetUsers {
                typealias APIResponse = [User]
            }
            """,
            expandedSource:
                """
                final class GetUsers {
                    typealias APIResponse = [User]
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@APIDefinition can only be attached to a struct so each endpoint remains an explicit Sendable value.",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro requires an explicit response contract")
    func apiDefinitionMissingResponse() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users", auth: .anonymous)
            struct GetUsers {}
            """,
            expandedSource:
                """
                struct GetUsers {}
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@APIDefinition requires an explicit typealias APIResponse so the response contract remains visible on the struct.",
                    line: 2,
                    column: 8
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects duplicate conformance")
    func apiDefinitionDuplicateConformance() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users", auth: .anonymous)
            struct GetUsers: APIDefinition {
                typealias APIResponse = [User]
            }
            """,
            expandedSource:
                """
                struct GetUsers: APIDefinition {
                    typealias APIResponse = [User]
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@APIDefinition adds APIDefinition conformance; remove the explicit conformance from the struct declaration.",
                    line: 2,
                    column: 18
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects body and query together")
    func apiDefinitionBodyQueryConflict() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .post, path: "/users", auth: .anonymous)
            struct SearchUsers {
                typealias APIResponse = [User]
                let body: SearchBody
                let query: SearchQuery
            }
            """,
            expandedSource:
                """
                struct SearchUsers {
                    typealias APIResponse = [User]
                    let body: SearchBody
                    let query: SearchQuery
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@APIDefinition simple mode accepts either body or query, not both.",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects inferred body types")
    func apiDefinitionInferredBodyType() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .post, path: "/users", auth: .anonymous)
            struct CreateUser {
                typealias APIResponse = User
                let body = CreateUserRequest(name: "Blob")
            }
            """,
            expandedSource:
                """
                struct CreateUser {
                    typealias APIResponse = User
                    let body = CreateUserRequest(name: "Blob")
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@APIDefinition body requires an explicit type annotation.",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects GET body inference")
    func apiDefinitionGetBody() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users", auth: .anonymous)
            struct SearchUsers {
                typealias APIResponse = [User]
                let body: SearchBody
            }
            """,
            expandedSource:
                """
                struct SearchUsers {
                    typealias APIResponse = [User]
                    let body: SearchBody
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@APIDefinition GET endpoints cannot infer a body; use the explicit Parameter + parameters fallback for a custom transport.",
                    line: 1,
                    column: 24
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects a partial manual payload contract")
    func apiDefinitionPartialManualContract() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .post, path: "/users", auth: .anonymous)
            struct CreateUser {
                typealias APIResponse = User
                typealias Parameter = CreateUserRequest
            }
            """,
            expandedSource:
                """
                struct CreateUser {
                    typealias APIResponse = User
                    typealias Parameter = CreateUserRequest
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@APIDefinition explicit Parameter requires a matching parameters property.",
                    line: 4,
                    column: 5
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects query and fragment path components")
    func apiDefinitionPathComponent() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users?page=1", auth: .anonymous)
            struct ListUsers {
                typealias APIResponse = [User]
            }
            """,
            expandedSource:
                """
                struct ListUsers {
                    typealias APIResponse = [User]
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@APIDefinition path must not contain query or fragment components; declare query values through the query property.",
                    line: 1,
                    column: 36
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro warns about redundant EmptyParameter")
    func apiDefinitionRedundantEmptyParameterWarning() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users", auth: .anonymous)
            struct ListUsers {
                typealias APIResponse = [User]
                typealias Parameter = EmptyParameter
            }
            """,
            expandedSource:
                """
                struct ListUsers {
                    typealias APIResponse = [User]
                    typealias Parameter = EmptyParameter
                }

                extension ListUsers: InnoNetwork.APIDefinition {
                    internal var sessionAuthentication: InnoNetwork.SessionAuthentication {
                        .anonymous
                    }
                    internal var method: InnoNetwork.HTTPMethod {
                        .get
                    }
                    internal var path: Swift.String {
                        "/users"
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "typealias Parameter = EmptyParameter is redundant; @APIDefinition synthesizes it for empty requests.",
                    line: 4,
                    column: 5,
                    severity: .warning
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects computed body inference")
    func apiDefinitionComputedBody() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .post, path: "/users", auth: .anonymous)
            struct CreateUser {
                typealias APIResponse = User
                var body: CreateUserRequest { CreateUserRequest() }
            }
            """,
            expandedSource:
                """
                struct CreateUser {
                    typealias APIResponse = User
                    var body: CreateUserRequest { CreateUserRequest() }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@APIDefinition simple-mode body must be an instance stored property; use a complete Parameter + parameters fallback for computed, static, or lazy payloads.",
                    line: 4,
                    column: 5
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects static query inference")
    func apiDefinitionStaticQuery() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users", auth: .anonymous)
            struct ListUsers {
                typealias APIResponse = [User]
                static let query = ListUsersQuery()
            }
            """,
            expandedSource:
                """
                struct ListUsers {
                    typealias APIResponse = [User]
                    static let query = ListUsersQuery()
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@APIDefinition simple-mode query must be an instance stored property; use a complete Parameter + parameters fallback for computed, static, or lazy payloads.",
                    line: 4,
                    column: 5
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects non-ASCII percent escapes")
    func apiDefinitionFullWidthPercentEscape() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/files/%ＦＦ", auth: .anonymous)
            struct GetFile {
                typealias APIResponse = FileResponse
            }
            """,
            expandedSource:
                """
                struct GetFile {
                    typealias APIResponse = FileResponse
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@APIDefinition path contains an invalid percent escape.",
                    line: 1,
                    column: 36
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects dynamic methods during payload inference")
    func apiDefinitionDynamicPayloadMethod() {
        assertMacroExpansion(
            """
            @APIDefinition(method: EndpointMethods.create, path: "/users", auth: .anonymous)
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
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@APIDefinition body/query inference requires method: to be an explicit HTTPMethod enum case.",
                    line: 1,
                    column: 24
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro accepts qualified method and auth cases")
    func apiDefinitionQualifiedCases() {
        assertMacroExpansion(
            """
            @APIDefinition(method: InnoNetwork.HTTPMethod.post, path: "/users", auth: InnoNetwork.SessionAuthentication.required)
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

                extension CreateUser: InnoNetwork.APIDefinition {
                    internal typealias Parameter = CreateUserRequest
                    internal var parameters: Parameter? {
                        func normalized<Value>(_ value: Value) -> Value? {
                            .some(value)
                        }
                        func normalized<Value>(_ value: Value?) -> Value?? {
                            guard let value else {
                                return nil
                            }
                            return .some(.some(value))
                        }
                        return normalized(body)
                    }
                    internal var sessionAuthentication: InnoNetwork.SessionAuthentication {
                        .required
                    }
                    internal var method: InnoNetwork.HTTPMethod {
                        InnoNetwork.HTTPMethod.post
                    }
                    internal var path: Swift.String {
                        "/users"
                    }
                }
                """,
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects stored values that would be silently dropped")
    func apiDefinitionRejectsUnusedStoredProperty() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .post, path: "/users", auth: .anonymous)
            struct CreateUser {
                typealias APIResponse = User
                let request: CreateUserRequest
            }
            """,
            expandedSource:
                """
                struct CreateUser {
                    typealias APIResponse = User
                    let request: CreateUserRequest
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@APIDefinition stored property 'request' is not used by the route or inferred payload. In simple mode place GET values in 'query' and non-GET values in 'body', or declare a complete Parameter + parameters fallback.",
                    line: 4,
                    column: 9
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects tuple-destructured stored values")
    func apiDefinitionRejectsTupleStoredPropertyPattern() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users", auth: .anonymous)
            struct ListUsers {
                typealias APIResponse = [User]
                let (page, limit): (Int, Int)
            }
            """,
            expandedSource:
                """
                struct ListUsers {
                    typealias APIResponse = [User]
                    let (page, limit): (Int, Int)
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@APIDefinition simple mode requires each stored property to use a single identifier; tuple and other destructuring patterns cannot be inferred. Declare individual stored properties or use a complete Parameter + parameters fallback.",
                    line: 4,
                    column: 9
                )
            ],
            macros: macros
        )
    }

    @Test("APIDefinition macro rejects nested destructuring before route inference")
    func apiDefinitionRejectsNestedStoredPropertyPattern() {
        assertMacroExpansion(
            """
            @APIDefinition(method: .get, path: "/users/{page}", auth: .anonymous)
            struct ListUsers {
                typealias APIResponse = [User]
                let (page, (offset, limit)): (Int, (Int, Int))
            }
            """,
            expandedSource:
                """
                struct ListUsers {
                    typealias APIResponse = [User]
                    let (page, (offset, limit)): (Int, (Int, Int))
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@APIDefinition simple mode requires each stored property to use a single identifier; tuple and other destructuring patterns cannot be inferred. Declare individual stored properties or use a complete Parameter + parameters fallback.",
                    line: 4,
                    column: 9
                )
            ],
            macros: macros
        )
    }
}
#endif
