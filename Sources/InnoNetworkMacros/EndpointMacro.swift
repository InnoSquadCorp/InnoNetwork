import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Implements the freestanding ``endpoint`` macro expansion.
public struct EndpointMacro: ExpressionMacro {
    /// Expands `#endpoint(_:_:as:)` into a fluent `Endpoint` builder expression.
    ///
    /// - Parameters:
    ///   - node: Freestanding macro expansion syntax containing method, path,
    ///     and `as:` response type arguments.
    ///   - context: Macro expansion context used by SwiftSyntax.
    /// - Returns: An expression equivalent to
    ///   `Endpoint<EmptyResponse>(method:path:).decoding(Response.self)`.
    /// - Throws: ``InnoNetworkMacroDiagnostic`` when the argument count is
    ///   invalid or the response type argument is not labeled `as:`.
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let arguments = node.arguments
        guard arguments.count == 3 else {
            throw InnoNetworkMacroDiagnostic(
                "#endpoint requires method, path, and as: response type arguments.",
                id: "endpoint-invalid-argument-count"
            )
        }

        let method = arguments[arguments.startIndex].expression.trimmedDescription
        let pathIndex = arguments.index(after: arguments.startIndex)
        let responseIndex = arguments.index(after: pathIndex)
        let path = arguments[pathIndex].expression.trimmedDescription
        let responseArgument = arguments[responseIndex]
        guard responseArgument.label?.text == "as" else {
            throw InnoNetworkMacroDiagnostic(
                "#endpoint third argument must be labeled as:.",
                id: "endpoint-missing-as-label"
            )
        }

        let responseType = responseArgument.expression.trimmedDescription
        return "Endpoint<EmptyResponse>(method: \(raw: method), path: \(raw: path)).decoding(\(raw: responseType))"
    }
}
