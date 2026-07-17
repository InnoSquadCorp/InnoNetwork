import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Implements the attached ``APIDefinition`` macro expansion.
public struct APIDefinitionMacro: ExtensionMacro {
    /// Expands `@APIDefinition(method:path:auth:)` into an `APIDefinition`
    /// conformance extension.
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDeclaration = declaration.as(StructDeclSyntax.self) else {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition can only be attached to a struct so each endpoint remains an explicit Sendable value.",
                id: "api-definition-non-struct"
            ).error(at: declaration)
        }
        if let conformance = directAPIDefinitionConformance(in: structDeclaration) {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition adds APIDefinition conformance; remove the explicit conformance from the struct declaration.",
                id: "api-definition-duplicate-conformance"
            ).error(at: conformance)
        }
        guard declaresTypeAlias(named: "APIResponse", in: structDeclaration) else {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition requires an explicit typealias APIResponse so the response contract remains visible on the struct.",
                id: "api-definition-missing-response"
            ).error(at: structDeclaration.name)
        }
        for ownedMember in ["method", "path", "sessionAuthentication"]
        where declaresVariable(named: ownedMember, in: structDeclaration) {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition owns the generated \(ownedMember) witness; remove the explicit \(ownedMember) property.",
                id: "api-definition-explicit-\(ownedMember)-conflict"
            ).error(at: structDeclaration)
        }

        let arguments = try argumentList(from: node)
        let methodArgument = try requiredArgument(named: "method", in: arguments)
        let method = canonicalMethodExpression(from: methodArgument.expression)
        let pathArgument = try requiredArgument(named: "path", in: arguments)
        let authArgument = try requiredArgument(named: "auth", in: arguments)
        let authentication = try authentication(from: authArgument)
        let pathLiteral = try stringLiteralArgument(named: "path", in: arguments)
        try validatePathLiteral(pathLiteral, anchor: pathArgument.expression)

        if !hasCompleteManualPayloadContract(in: structDeclaration) {
            try validateSimpleStoredPropertyPatterns(in: structDeclaration)
            try validateSimplePayloadDeclarations(in: structDeclaration)
        }
        let properties = storedProperties(in: declaration)
        var pathProperties: Set<String> = []
        let path = try interpolatedPath(
            pathLiteral,
            properties: properties,
            usedProperties: &pathProperties,
            anchor: pathArgument.expression
        )
        if !hasCompleteManualPayloadContract(in: structDeclaration) {
            try validateEveryStoredPropertyIsConsumed(
                in: structDeclaration,
                pathProperties: pathProperties
            )
        }

        let typeName = type.trimmedDescription
        let accessPrefix = witnessAccessPrefix(in: declaration)
        diagnoseRedundantEmptyParameter(
            in: declaration,
            properties: properties,
            context: context
        )
        var witnesses = try payloadWitnesses(
            in: declaration,
            properties: properties,
            method: methodArgument.expression,
            anchor: methodArgument.expression,
            accessPrefix: accessPrefix
        )
        witnesses.append(
            "\(accessPrefix)var sessionAuthentication: InnoNetwork.SessionAuthentication { .\(authentication.caseName) }"
        )
        witnesses.append("\(accessPrefix)var method: InnoNetwork.HTTPMethod { \(method) }")
        witnesses.append(
            pathWitness(
                path,
                hasPlaceholders: !pathProperties.isEmpty,
                accessPrefix: accessPrefix
            )
        )
        return [
            try ExtensionDeclSyntax(
                """
                extension \(raw: typeName): InnoNetwork.APIDefinition {
                    \(raw: indentedWitnessSource(witnesses))
                }
                """
            )
        ]
    }

    private static func diagnoseRedundantEmptyParameter(
        in declaration: some DeclGroupSyntax,
        properties: [String: StoredProperty],
        context: some MacroExpansionContext
    ) {
        guard let parameterAlias = typeAlias(named: "Parameter", in: declaration),
            isEmptyParameterType(parameterAlias.initializer.value),
            !declaresVariable(named: "parameters", in: declaration),
            properties["body"] == nil,
            properties["query"] == nil
        else {
            return
        }
        context.diagnose(
            InnoNetworkMacroDiagnostic(
                "typealias Parameter = EmptyParameter is redundant; @APIDefinition synthesizes it for empty requests.",
                id: "api-definition-redundant-empty-parameter",
                severity: .warning
            ).diagnostic(at: parameterAlias)
        )
    }

    private static func indentedWitnessSource(_ witnesses: [String]) -> String {
        witnesses
            .map {
                $0.split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                    .joined(separator: "\n    ")
            }
            .joined(separator: "\n    ")
    }
}
