import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Implements the freestanding ``endpoint`` macro expansion.
public struct EndpointMacro: ExpressionMacro {
    /// Expands `#endpoint(_:_:as:)` into a fluent `ScopedEndpoint` builder expression.
    ///
    /// - Parameters:
    ///   - node: Freestanding macro expansion syntax containing method, path,
    ///     and `as:` response type arguments.
    ///   - context: Macro expansion context used by SwiftSyntax.
    /// - Returns: An expression equivalent to
    ///   `ScopedEndpoint<EmptyResponse, PublicAuthScope>(method:path:).decoding(Response.self)`.
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
            ).error(at: node)
        }

        let methodArgument = arguments[arguments.startIndex]
        guard methodArgument.label == nil else {
            throw InnoNetworkMacroDiagnostic(
                "#endpoint first argument (method) must be unlabeled.",
                id: "endpoint-unexpected-method-label"
            ).error(at: methodArgument)
        }
        let method = methodArgument.expression.trimmedDescription
        let pathIndex = arguments.index(after: arguments.startIndex)
        let responseIndex = arguments.index(after: pathIndex)
        let pathArgument = arguments[pathIndex]
        guard pathArgument.label == nil else {
            throw InnoNetworkMacroDiagnostic(
                "#endpoint second argument (path) must be unlabeled.",
                id: "endpoint-unexpected-path-label"
            ).error(at: pathArgument)
        }
        let path = pathArgument.expression.trimmedDescription
        let responseArgument = arguments[responseIndex]
        guard responseArgument.label?.text == "as" else {
            throw InnoNetworkMacroDiagnostic(
                "#endpoint third argument must be labeled as:.",
                id: "endpoint-missing-as-label"
            ).error(at: responseArgument)
        }

        let responseType = responseArgument.expression.trimmedDescription
        return "ScopedEndpoint<EmptyResponse, PublicAuthScope>(method: \(raw: method), path: \(raw: path)).decoding(\(raw: responseType))"
    }
}
