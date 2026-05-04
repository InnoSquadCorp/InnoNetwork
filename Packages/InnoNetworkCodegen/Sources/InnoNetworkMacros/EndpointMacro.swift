import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Implements the freestanding ``endpoint`` macro expansion.
public struct EndpointMacro: ExpressionMacro {
    /// Expands `#endpoint(_:_:as:)` (or `#endpoint(_:_:as:scope:)`) into a
    /// fluent `ScopedEndpoint` builder expression.
    ///
    /// - Parameters:
    ///   - node: Freestanding macro expansion syntax containing method, path,
    ///     `as:` response type, and optionally `scope:` auth-scope arguments.
    ///   - context: Macro expansion context used by SwiftSyntax.
    /// - Returns: An expression equivalent to
    ///   `ScopedEndpoint<EmptyResponse, Scope>(method:path:).decoding(Response.self)`,
    ///   where `Scope` is `PublicAuthScope` for the three-argument form or
    ///   the concrete metatype passed via `scope:` for the four-argument form.
    /// - Throws: ``InnoNetworkMacroDiagnostic`` when the argument count is
    ///   invalid or the response type argument is not labeled `as:`.
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let arguments = node.arguments
        guard arguments.count == 3 || arguments.count == 4 else {
            throw InnoNetworkMacroDiagnostic(
                "#endpoint requires method, path, and as: response type arguments (with optional scope:).",
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

        let scopeName: String
        if arguments.count == 4 {
            let scopeIndex = arguments.index(after: responseIndex)
            let scopeArgument = arguments[scopeIndex]
            guard scopeArgument.label?.text == "scope" else {
                throw InnoNetworkMacroDiagnostic(
                    "#endpoint fourth argument must be labeled scope:.",
                    id: "endpoint-missing-scope-label"
                ).error(at: scopeArgument)
            }
            // The argument is a metatype expression like `AuthRequiredScope.self`.
            // Strip the trailing `.self` so the result interpolates as a
            // generic parameter inside `ScopedEndpoint<EmptyResponse, _>`.
            let scopeExpression = scopeArgument.expression.trimmedDescription
            guard scopeExpression.hasSuffix(".self") else {
                throw InnoNetworkMacroDiagnostic(
                    "#endpoint scope: argument must be a metatype expression (e.g. AuthRequiredScope.self).",
                    id: "endpoint-invalid-scope-argument"
                ).error(at: scopeArgument)
            }
            scopeName = String(scopeExpression.dropLast(".self".count))
        } else {
            scopeName = "PublicAuthScope"
        }

        let builder = "ScopedEndpoint<EmptyResponse, \(scopeName)>"
        return "\(raw: builder)(method: \(raw: method), path: \(raw: path)).decoding(\(raw: responseType))"
    }
}
