import SwiftSyntax

extension APIDefinitionMacro {
    static func payloadWitnesses(
        in declaration: some DeclGroupSyntax,
        properties: [String: StoredProperty],
        method: ExprSyntax,
        anchor: some SyntaxProtocol,
        accessPrefix: String
    ) throws -> [String] {
        let parameterAlias = typeAlias(named: "Parameter", in: declaration)
        let parametersDeclaration = variableBinding(named: "parameters", in: declaration)
        let hasParameters = parametersDeclaration != nil

        if let (variable, _) = parametersDeclaration,
            hasNonInstanceModifier(variable)
        {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition explicit parameters must be an instance property.",
                id: "api-definition-static-parameters-witness"
            ).error(at: variable)
        }

        if parameterAlias != nil, hasParameters {
            return []
        }

        if let parameterAlias, !hasParameters {
            if isEmptyParameterType(parameterAlias.initializer.value) {
                if properties["body"] != nil || properties["query"] != nil {
                    throw InnoNetworkMacroDiagnostic(
                        "@APIDefinition body/query inference conflicts with the explicit EmptyParameter alias; remove the alias or use a complete Parameter + parameters fallback.",
                        id: "api-definition-empty-parameter-payload-conflict"
                    ).error(at: parameterAlias)
                }
                return []
            }
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition explicit Parameter requires a matching parameters property.",
                id: "api-definition-missing-parameters-witness"
            ).error(at: parameterAlias)
        }

        if parameterAlias == nil, hasParameters {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition explicit parameters requires a matching typealias Parameter.",
                id: "api-definition-missing-parameter-alias"
            ).error(at: declaration)
        }

        let body = properties["body"]
        let query = properties["query"]
        if body != nil, query != nil {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition simple mode accepts either body or query, not both.",
                id: "api-definition-body-query-conflict"
            ).error(at: declaration)
        }

        if let body {
            switch methodKind(method) {
            case .queryOnly(let name):
                throw InnoNetworkMacroDiagnostic(
                    "@APIDefinition \(name) endpoints cannot infer a body; use the explicit Parameter + parameters fallback for a custom transport.",
                    id: "api-definition-query-method-body"
                ).error(at: anchor)
            case .requiresExplicitPayload:
                throw InnoNetworkMacroDiagnostic(
                    simplePayloadMethodDiagnostic,
                    id: "api-definition-dynamic-payload-method"
                ).error(at: anchor)
            case .body:
                break
            }
            let parameterType = try parameterTypeName(for: body, role: "body", anchor: declaration)
            return [
                "\(accessPrefix)typealias Parameter = \(parameterType)",
                normalizedParametersWitness(
                    property: "body",
                    accessPrefix: accessPrefix
                ),
            ]
        }

        if let query {
            switch methodKind(method) {
            case .body:
                throw InnoNetworkMacroDiagnostic(
                    "@APIDefinition query inference is supported only for GET and HEAD endpoints; use the explicit Parameter + parameters fallback for a custom transport.",
                    id: "api-definition-nonget-query"
                ).error(at: anchor)
            case .requiresExplicitPayload:
                throw InnoNetworkMacroDiagnostic(
                    simplePayloadMethodDiagnostic,
                    id: "api-definition-dynamic-payload-method"
                ).error(at: anchor)
            case .queryOnly:
                break
            }
            let parameterType = try parameterTypeName(for: query, role: "query", anchor: declaration)
            return [
                "\(accessPrefix)typealias Parameter = \(parameterType)",
                normalizedParametersWitness(
                    property: "query",
                    accessPrefix: accessPrefix
                ),
            ]
        }

        return ["\(accessPrefix)typealias Parameter = InnoNetwork.EmptyParameter"]
    }

    static func isEmptyParameterType(_ type: TypeSyntax) -> Bool {
        let source = type.trimmedDescription
        return source == "EmptyParameter" || source == "InnoNetwork.EmptyParameter"
    }

    static func normalizedParametersWitness(
        property: String,
        accessPrefix: String
    ) -> String {
        """
        \(accessPrefix)var parameters: Parameter? {
            func normalized<Value>(_ value: Value) -> Value? {
                .some(value)
            }
            func normalized<Value>(_ value: Value?) -> Value?? {
                guard let value else { return nil }
                return .some(.some(value))
            }
            return normalized(\(property))
        }
        """
    }

    static func parameterTypeName(
        for property: StoredProperty,
        role: String,
        anchor: some SyntaxProtocol
    ) throws -> String {
        guard let type = property.type else {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition \(role) requires an explicit type annotation.",
                id: "api-definition-inferred-\(role)-type"
            ).error(at: anchor)
        }

        let source = type.trimmedDescription
        if source.hasSuffix("!") {
            return "\(source.dropLast())?"
        }
        return source
    }
}
