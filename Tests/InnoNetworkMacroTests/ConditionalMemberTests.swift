#if Macros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import InnoNetworkMacros

@Suite("Conditional endpoint contract admission")
struct ConditionalMemberTests {
    @Test(arguments: ["os(macOS)", "os(Linux)", "FEATURE_FLAG"])
    func rejectsBranchesBeforePayloadInference(condition: String) {
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
            expandedSource: declaration,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@APIDefinition does not support conditional members; place #if around the entire endpoint declaration or use a manual endpoint.",
                    line: 4, column: 5)
            ],
            macros: ["APIDefinition": APIDefinitionMacro.self])
    }
}
#endif
