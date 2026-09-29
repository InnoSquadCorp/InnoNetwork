#if Macros
import SwiftSyntax
import Testing

@testable import InnoNetworkMacros

@Suite("Macro path admission")
struct MacroPathValidationTests {
    @Test func nestedPathAdmission() throws {
        let nested = "%" + String(repeating: "25", count: 32768)
        for path in ["/" + nested + "2E", "/" + nested + "5C..", "/%25%32%45", "/%FF/%2e", "/\\..\\admin"] {
            #expect(APIDefinitionMacro.containsDotSegment(path))
        }
        for path in ["/" + nested + "41", "/" + nested + "2Efile", "/100%25", "/a%2Fb", "/é/file.json"] {
            #expect(!APIDefinitionMacro.containsDotSegment(path))
        }
    }

    @Test func scalarPercentEscapes() throws {
        let anchor = StringLiteralExprSyntax(content: "path")
        for path in ["/items/%41", "/items/A\u{0301}", "/items/%41\u{0301}"] {
            try APIDefinitionMacro.validatePathLiteral(path, anchor: anchor)
        }
        for path in ["/items/%\u{0301}41", "/items/%4\u{0301}1", "/items/%4G"] {
            #expect(throws: (any Error).self) {
                try APIDefinitionMacro.validatePathLiteral(path, anchor: anchor)
            }
        }
    }
}
#endif
