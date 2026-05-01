import SwiftDiagnostics
import SwiftSyntax

struct InnoNetworkMacroDiagnostic: DiagnosticMessage, Error {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity

    init(_ message: String, id: String) {
        self.message = message
        self.diagnosticID = MessageID(domain: "InnoNetworkMacros", id: id)
        self.severity = .error
    }

    /// Wraps the diagnostic in a `DiagnosticsError` whose source location
    /// points at `node`. Throwing this from a macro expansion makes the IDE
    /// underline the offending argument or token instead of dropping the
    /// diagnostic on the macro attribute as a whole.
    func error(at node: some SyntaxProtocol) -> DiagnosticsError {
        DiagnosticsError(diagnostics: [
            Diagnostic(node: Syntax(node), message: self)
        ])
    }
}
