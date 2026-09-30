import Foundation
import SwiftDiagnostics
import SwiftSyntax

/// Compiler-host analysis result. This product must not be linked into app runtime targets.
public struct EncodedEndpointExpansion {
    public let typeName: String
    public let accessPrefix: String
    public let methodExpression: String
    public let authenticationExpression: String
    public let pathWitness: String
    public let hasBody: Bool
    public let hasQuery: Bool
    public let presentPolicies: Set<String>
}

extension EndpointDefinitionExpansion {
    /// Shares route, authentication and declaration validation with companion macros.
    /// Payload conformance is checked by the compiler against generated typed factories.
    public static func analyzeEncoded(
        attribute: AttributeSyntax, declaration: some DeclGroupSyntax,
        type: some TypeSyntaxProtocol, macroName: String, policyNames: Set<String>
    ) throws -> EncodedEndpointExpansion {
        do {
            return try analyzeEncodedImplementation(
                attribute: attribute, declaration: declaration,
                type: type, policyNames: policyNames)
        } catch let error as DiagnosticsError {
            throw DiagnosticsError(
                diagnostics: error.diagnostics.map { diagnostic in
                    Diagnostic(
                        node: diagnostic.node, position: diagnostic.position,
                        message: InnoNetworkMacroDiagnostic(
                            diagnostic.message.replacingOccurrences(of: "@APIDefinition", with: macroName)
                                .replacingOccurrences(
                                    of: "a complete Parameter + parameters fallback",
                                    with: "a manual EncodedAPIDefinition or EncodedRequest factory"),
                            id: "encoded-endpoint-invalid-declaration", severity: diagnostic.diagMessage.severity),
                        highlights: diagnostic.highlights, notes: diagnostic.notes, fixIts: diagnostic.fixIts)
                })
        }
    }

    private static func analyzeEncodedImplementation(
        attribute: AttributeSyntax, declaration: some DeclGroupSyntax,
        type: some TypeSyntaxProtocol, policyNames: Set<String>
    ) throws -> EncodedEndpointExpansion {
        func fail(_ message: String, at node: some SyntaxProtocol) -> DiagnosticsError {
            InnoNetworkMacroDiagnostic("@APIDefinition " + message, id: "encoded-endpoint-invalid-declaration")
                .error(at: node)
        }
        guard let structure = declaration.as(StructDeclSyntax.self) else {
            throw fail("can only be attached to a struct.", at: declaration)
        }
        guard declaresTypeAlias(named: "APIResponse", in: structure) else {
            throw fail("requires an explicit typealias APIResponse.", at: structure.name)
        }
        if let inherited = structure.inheritanceClause?.inheritedTypes.first(where: {
            let name = $0.type.trimmedDescription.split(separator: ".").last
            return name == "EncodedAPIDefinition" || name == "APIDefinition"
        }) {
            throw fail("owns endpoint conformance; remove the explicit conformance.", at: inherited)
        }
        for name in ["method", "path", "sessionAuthentication", "makeEncodedRequest", "parameters"] {
            if declaresVariable(named: name, in: structure)
                || structure.memberBlock.members.contains(where: {
                    $0.decl.as(FunctionDeclSyntax.self)?.name.text == name
                })
            {
                throw fail("owns \(name); remove the conflicting member.", at: structure)
            }
        }
        if declaresTypeAlias(named: "Parameter", in: structure) {
            throw fail("uses body/query, not a Codable Parameter alias.", at: structure)
        }
        let arguments = try argumentList(from: attribute)
        let methodArgument = try requiredArgument(named: "method", in: arguments)
        guard let method = explicitHTTPMethodName(from: methodArgument.expression),
            ["get", "head", "post", "put", "patch", "delete", "options", "trace"].contains(method)
        else {
            throw fail(
                "requires an explicit supported HTTP method; use a manual endpoint for other methods.",
                at: methodArgument)
        }
        let auth = try authentication(from: requiredArgument(named: "auth", in: arguments))
        let pathArgument = try requiredArgument(named: "path", in: arguments)
        let literal = try stringLiteralArgument(named: "path", in: arguments)
        try validatePathLiteral(literal, anchor: pathArgument.expression)
        try validateSimpleStoredPropertyPatterns(in: structure)
        try validateSimplePayloadDeclarations(in: structure)
        let properties = storedProperties(in: structure)
        for role in ["body", "query"] {
            if let property = properties[role], property.type == nil {
                throw fail("\(role) requires an explicit type annotation.", at: structure)
            }
        }
        if properties["body"] != nil, ["get", "head", "trace"].contains(method) {
            throw fail("\(method.uppercased()) endpoints cannot declare a body.", at: methodArgument)
        }
        var presentPolicies: Set<String> = []
        for name in policyNames {
            if let (variable, _) = variableBinding(named: name, in: structure) {
                guard !hasNonInstanceModifier(variable) else {
                    throw fail("\(name) must be an instance policy property, not static or lazy.", at: variable)
                }
                presentPolicies.insert(name)
            }
        }
        var pathProperties: Set<String> = []
        let path = try interpolatedPath(
            literal, properties: properties, usedProperties: &pathProperties,
            anchor: pathArgument.expression)
        let consumed = pathProperties.union(["body", "query"]).union(policyNames)
        for name in properties.keys.sorted() where !consumed.contains(name) {
            throw fail(
                "stored property '\(name)' is not used by the route, body, query or request policies.", at: structure)
        }
        let access = witnessAccessPrefix(in: declaration)
        return EncodedEndpointExpansion(
            typeName: type.trimmedDescription, accessPrefix: access,
            methodExpression: ".\(method)", authenticationExpression: ".\(auth.caseName)",
            pathWitness: pathWitness(path, hasPlaceholders: !pathProperties.isEmpty, accessPrefix: access),
            hasBody: properties["body"] != nil, hasQuery: properties["query"] != nil, presentPolicies: presentPolicies)
    }
}
