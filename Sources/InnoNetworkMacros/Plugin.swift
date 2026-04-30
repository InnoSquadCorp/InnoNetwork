import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct InnoNetworkMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        APIDefinitionMacro.self,
        EndpointMacro.self,
    ]
}
