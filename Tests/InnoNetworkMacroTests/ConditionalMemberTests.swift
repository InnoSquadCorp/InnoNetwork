#if Macros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import InnoNetworkMacros

@Suite("Conditional endpoint contract admission")
struct ConditionalMemberTests {
    @Test(arguments: ["os(macOS)", "os(Linux)", "FEATURE_FLAG"])
    func warnsWithoutChangingLegacyPayloadInference(condition: String) {
        let declaration = """
            struct Conditional {
                typealias APIResponse = String
                #if \(condition)
                let body: String
                #else
                #if DEBUG
                let query: String
                #endif
                #endif
            }
            """
        assertMacroExpansion(
            "@APIDefinition(method: .post, path: \"/\", auth: .anonymous)\n" + declaration,
            expandedSource: expanded(declaration),
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@APIDefinition does not infer conditional body/query or payload witnesses; 6.x preserves the unconditional payload contract. Place #if around the whole endpoint or declare unconditional Parameter + parameters.",
                    line: 4, column: 5, severity: .warning)
            ],
            macros: ["APIDefinition": APIDefinitionMacro.self])
    }

    @Test(arguments: [
        "func diagnosticLabel() -> String { \"health\" }",
        "var headers: HTTPHeaders { [\"X-Debug\": \"1\"] }",
        "struct Helper {\n        let body: String\n    }",
        "func helper() { let body = \"local\"; _ = body }",
        "#if NESTED\nfunc helper() {}\n#endif",
    ])
    func preservesUnrelatedConditionalMembers(member: String) {
        let declaration = """
            struct Conditional {
                typealias APIResponse = String
                #if DEBUG
                \(member)
                #endif
            }
            """
        assertMacroExpansion(
            "@APIDefinition(method: .post, path: \"/\", auth: .anonymous)\n" + declaration,
            expandedSource: expanded(declaration),
            macros: ["APIDefinition": APIDefinitionMacro.self])
    }

    @Test(arguments: ["let `query`: String", "typealias Parameter = String", "var parameters: String? { nil }"])
    func warnsForConditionalPayloadWitnesses(member: String) {
        let declaration = """
            struct Conditional {
                typealias APIResponse = String
                #if DEBUG
                \(member)
                #endif
            }
            """
        assertMacroExpansion(
            "@APIDefinition(method: .post, path: \"/\", auth: .anonymous)\n" + declaration,
            expandedSource: expanded(declaration),
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@APIDefinition does not infer conditional body/query or payload witnesses; 6.x preserves the unconditional payload contract. Place #if around the whole endpoint or declare unconditional Parameter + parameters.",
                    line: 4, column: 5, severity: .warning)
            ],
            macros: ["APIDefinition": APIDefinitionMacro.self])
    }

    @Test func preservesAuthoritativeManualPayloadWithoutWarning() {
        let declaration = """
            struct Conditional {
                typealias APIResponse = String
                typealias Parameter = String
                var parameters: String? { body }
                #if DEBUG
                var body: String { "debug" }
                #else
                var body: String { "release" }
                #endif
            }
            """
        assertMacroExpansion(
            "@APIDefinition(method: .post, path: \"/\", auth: .anonymous)\n" + declaration,
            expandedSource: expanded(declaration, inferEmptyParameter: false),
            macros: ["APIDefinition": APIDefinitionMacro.self])
    }

    private func expanded(_ declaration: String, inferEmptyParameter: Bool = true) -> String {
        let parameter = inferEmptyParameter ? "    internal typealias Parameter = InnoNetwork.EmptyParameter\n" : ""
        return declaration + "\n\n" + """
            extension Conditional: InnoNetwork.APIDefinition {
            \(parameter)    internal var sessionAuthentication: InnoNetwork.SessionAuthentication {
                    .anonymous
                }
                internal var method: InnoNetwork.HTTPMethod {
                    .post
                }
                internal var path: Swift.String {
                    "/"
                }
            }
            """
    }
}
#endif
