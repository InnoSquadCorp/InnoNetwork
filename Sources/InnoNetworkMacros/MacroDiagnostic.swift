import SwiftDiagnostics

struct InnoNetworkMacroDiagnostic: DiagnosticMessage, Error {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity

    init(_ message: String, id: String) {
        self.message = message
        self.diagnosticID = MessageID(domain: "InnoNetworkMacros", id: id)
        self.severity = .error
    }
}
