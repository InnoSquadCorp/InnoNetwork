import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct EndpointMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let expressions = node.arguments.map {
            $0.expression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let method = expressions.indices.contains(0) ? expressions[0] : ".get"
        let path = expressions.indices.contains(1) ? expressions[1] : "\"/\""
        let responseType = expressions.indices.contains(2) ? expressions[2] : "EmptyResponse.self"
        return "Endpoint<EmptyResponse>(method: \(raw: method), path: \(raw: path)).decoding(\(raw: responseType))"
    }
}
