import InnoNetworkMacroSupport
import SwiftSyntax
import SwiftSyntaxMacros

/// JSON endpoint expansion backed by the shared compile-time validator.
public struct APIDefinitionMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        try EndpointDefinitionExpansion.expansion(
            of: node, attachedTo: declaration, providingExtensionsOf: type,
            conformingTo: protocols, in: context)
    }
}
