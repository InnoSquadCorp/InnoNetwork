import SwiftDiagnostics
import SwiftSyntax

struct InnoNetworkMacroDiagnostic: DiagnosticMessage, Error {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity

    init(
        _ message: String,
        id: String,
        severity: DiagnosticSeverity = .error
    ) {
        self.message = message
        self.diagnosticID = MessageID(domain: "InnoNetworkMacros", id: id)
        self.severity = severity
    }

    /// Creates a diagnostic that can be emitted without aborting expansion.
    /// Use this for warning-only guidance; definite request-shape violations
    /// should continue to throw ``error(at:fixIts:)``.
    func diagnostic(
        at node: some SyntaxProtocol,
        fixIts: [FixIt] = []
    ) -> Diagnostic {
        Diagnostic(
            node: Syntax(node),
            message: self,
            fixIts: fixIts
        )
    }

    /// Wraps the diagnostic in a `DiagnosticsError` whose source location
    /// points at `node`. Throwing this from a macro expansion makes the IDE
    /// underline the offending argument or token instead of dropping the
    /// diagnostic on the macro attribute as a whole.
    ///
    /// `fixIts` lets a call site attach actionable corrections so the IDE
    /// surfaces them as one-click "Fix" suggestions instead of leaving the
    /// author to interpret the error message and edit the source by hand.
    /// Pass an empty array (the default) when no machine-applicable fix is
    /// available — emitting a placeholder FixIt with unparseable text is
    /// worse than no FixIt at all.
    func error(
        at node: some SyntaxProtocol,
        fixIts: [FixIt] = []
    ) -> DiagnosticsError {
        DiagnosticsError(diagnostics: [
            diagnostic(at: node, fixIts: fixIts)
        ])
    }
}

struct InnoNetworkMacroFixItMessage: FixItMessage {
    let message: String
    let fixItID: MessageID

    init(_ message: String, id: String) {
        self.message = message
        self.fixItID = MessageID(domain: "InnoNetworkMacros", id: id)
    }
}
