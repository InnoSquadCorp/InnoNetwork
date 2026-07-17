import SwiftSyntax

extension APIDefinitionMacro {
    struct StoredProperty {
        let isOptional: Bool
        let typeKind: TypeKind
        let type: TypeSyntax?
    }

    enum TypeKind {
        case concrete
        case opaque
        case genericParameter
    }

    enum VisibilityLevel: Int, Comparable {
        case `private` = 0
        case `fileprivate` = 1
        case `internal` = 2
        case `package` = 3
        case `public` = 4

        static func < (lhs: VisibilityLevel, rhs: VisibilityLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var witnessPrefix: String {
            switch self {
            case .public: return "public "
            case .package: return "package "
            case .internal: return "internal "
            case .fileprivate, .private:
                return "fileprivate "
            }
        }
    }

    static func directAPIDefinitionConformance(
        in declaration: StructDeclSyntax
    ) -> InheritedTypeSyntax? {
        declaration.inheritanceClause?.inheritedTypes.first { inherited in
            let name = inherited.type.trimmedDescription
            return name == "APIDefinition" || name.hasSuffix(".APIDefinition")
        }
    }

    static func hasCompleteManualPayloadContract(
        in declaration: some DeclGroupSyntax
    ) -> Bool {
        typeAlias(named: "Parameter", in: declaration) != nil
            && instanceVariable(named: "parameters", in: declaration) != nil
    }

    static func validateSimplePayloadDeclarations(
        in declaration: some DeclGroupSyntax
    ) throws {
        for role in ["body", "query"] {
            guard let (variable, binding) = variableBinding(named: role, in: declaration) else {
                continue
            }
            guard isEligibleStoredInstanceProperty(variable: variable, binding: binding) else {
                throw InnoNetworkMacroDiagnostic(
                    "@APIDefinition simple-mode \(role) must be an instance stored property; use a complete Parameter + parameters fallback for computed, static, or lazy payloads.",
                    id: "api-definition-invalid-\(role)-declaration"
                ).error(at: variable)
            }
        }
    }

    static func validateSimpleStoredPropertyPatterns(
        in declaration: some DeclGroupSyntax
    ) throws {
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in variable.bindings {
                guard isEligibleStoredInstanceProperty(variable: variable, binding: binding),
                    !binding.pattern.is(IdentifierPatternSyntax.self)
                else {
                    continue
                }
                throw InnoNetworkMacroDiagnostic(
                    "@APIDefinition simple mode requires each stored property to use a single identifier; tuple and other destructuring patterns cannot be inferred. Declare individual stored properties or use a complete Parameter + parameters fallback.",
                    id: "api-definition-nonidentifier-stored-property"
                ).error(at: binding.pattern)
            }
        }
    }

    static func validateEveryStoredPropertyIsConsumed(
        in declaration: some DeclGroupSyntax,
        pathProperties: Set<String>
    ) throws {
        let endpointWitnesses: Set<String> = [
            "headers",
            "logger",
            "requestInterceptors",
            "requestSigners",
            "responseInterceptors",
            "acceptableStatusCodes",
            "transport",
            "timeoutOverride",
            "cachePolicyOverride",
            "priorityOverride",
            "allowsCellularAccessOverride",
            "allowsExpensiveNetworkAccessOverride",
            "allowsConstrainedNetworkAccessOverride",
        ]
        let consumed =
            pathProperties
            .union(["body", "query"])
            .union(endpointWitnesses)

        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in variable.bindings {
                guard isEligibleStoredInstanceProperty(variable: variable, binding: binding),
                    let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                    !consumed.contains(identifier)
                else {
                    continue
                }
                throw InnoNetworkMacroDiagnostic(
                    "@APIDefinition stored property '\(identifier)' is not used by the route or inferred payload. In simple mode place GET/HEAD values in 'query' and POST/PUT/PATCH/DELETE values in 'body'; for every other method declare a complete Parameter + parameters fallback.",
                    id: "api-definition-unused-stored-property"
                ).error(at: binding.pattern)
            }
        }
    }

    static func storedProperties(
        in declaration: some DeclGroupSyntax
    ) -> [String: StoredProperty] {
        let genericParameters = genericParameterNames(in: declaration)
        var properties: [String: StoredProperty] = [:]
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in variable.bindings {
                guard isEligibleStoredInstanceProperty(variable: variable, binding: binding),
                    let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                else {
                    continue
                }
                let type = binding.typeAnnotation?.type
                properties[identifier] = StoredProperty(
                    isOptional: isOptionalType(type),
                    typeKind: classifyType(type, genericParameters: genericParameters),
                    type: type
                )
            }
        }
        return properties
    }

    static func typeAlias(
        named name: String,
        in declaration: some DeclGroupSyntax
    ) -> TypeAliasDeclSyntax? {
        declaration.memberBlock.members.lazy.compactMap { member in
            member.decl.as(TypeAliasDeclSyntax.self)
        }.first { $0.name.text == name }
    }

    static func declaresTypeAlias(
        named name: String,
        in declaration: some DeclGroupSyntax
    ) -> Bool {
        typeAlias(named: name, in: declaration) != nil
    }

    static func declaresVariable(
        named name: String,
        in declaration: some DeclGroupSyntax
    ) -> Bool {
        variableBinding(named: name, in: declaration) != nil
    }

    static func instanceVariable(
        named name: String,
        in declaration: some DeclGroupSyntax
    ) -> VariableDeclSyntax? {
        guard let (variable, _) = variableBinding(named: name, in: declaration),
            !hasNonInstanceModifier(variable)
        else {
            return nil
        }
        return variable
    }

    static func variableBinding(
        named name: String,
        in declaration: some DeclGroupSyntax
    ) -> (VariableDeclSyntax, PatternBindingSyntax)? {
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in variable.bindings {
                if binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name {
                    return (variable, binding)
                }
            }
        }
        return nil
    }

    static func isEligibleStoredInstanceProperty(
        variable: VariableDeclSyntax,
        binding: PatternBindingSyntax
    ) -> Bool {
        guard !hasNonInstanceModifier(variable) else { return false }
        guard let accessorBlock = binding.accessorBlock else { return true }

        switch accessorBlock.accessors {
        case .getter:
            return false
        case .accessors(let accessors):
            return accessors.allSatisfy { accessor in
                switch accessor.accessorSpecifier.text {
                case "willSet", "didSet":
                    return true
                default:
                    return false
                }
            }
        }
    }

    static func hasNonInstanceModifier(_ variable: VariableDeclSyntax) -> Bool {
        variable.modifiers.contains { modifier in
            switch modifier.name.text {
            case "static", "class", "lazy":
                return true
            default:
                return false
            }
        }
    }

    static func genericParameterNames(
        in declaration: some DeclGroupSyntax
    ) -> Set<String> {
        var names: Set<String> = []
        var cursor: Syntax? = Syntax(declaration)
        while let current = cursor {
            for name in genericParameters(on: current) {
                names.insert(name)
            }
            cursor = current.parent
        }
        return names
    }

    static func genericParameters(on syntax: Syntax) -> [String] {
        let clause: GenericParameterClauseSyntax?
        if let declaration = syntax.as(StructDeclSyntax.self) {
            clause = declaration.genericParameterClause
        } else if let declaration = syntax.as(ClassDeclSyntax.self) {
            clause = declaration.genericParameterClause
        } else if let declaration = syntax.as(ActorDeclSyntax.self) {
            clause = declaration.genericParameterClause
        } else if let declaration = syntax.as(EnumDeclSyntax.self) {
            clause = declaration.genericParameterClause
        } else {
            clause = nil
        }
        guard let clause else { return [] }
        return clause.parameters.map { $0.name.text }
    }

    static func classifyType(
        _ type: TypeSyntax?,
        genericParameters: Set<String>
    ) -> TypeKind {
        guard let type else { return .concrete }
        if let constrained = type.as(SomeOrAnyTypeSyntax.self),
            constrained.someOrAnySpecifier.text == "some"
        {
            return .opaque
        }
        if let identifier = type.as(IdentifierTypeSyntax.self),
            identifier.genericArgumentClause == nil,
            genericParameters.contains(identifier.name.text)
        {
            return .genericParameter
        }
        return .concrete
    }

    static func isOptionalType(_ type: TypeSyntax?) -> Bool {
        guard let type else { return false }
        if type.is(OptionalTypeSyntax.self) || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return true
        }
        let normalized = String(type.trimmedDescription.filter { $0 != " " })
        return normalized.hasPrefix("Optional<") || normalized.hasPrefix("Swift.Optional<")
    }

    static func witnessAccessPrefix(in declaration: some DeclGroupSyntax) -> String {
        let levels = collectVisibilityLevels(from: Syntax(declaration))
        let effective =
            levels.first.map { first in
                levels.dropFirst().reduce(first) { min($0, $1) }
            } ?? .internal
        return effective.witnessPrefix
    }

    static func collectVisibilityLevels(from syntax: Syntax) -> [VisibilityLevel] {
        var levels: [VisibilityLevel] = []
        var cursor: Syntax? = syntax
        while let current = cursor {
            if let level = visibilityLevel(of: current) {
                levels.append(level)
            }
            cursor = current.parent
        }
        return levels
    }

    static func visibilityLevel(of syntax: Syntax) -> VisibilityLevel? {
        let modifiers: DeclModifierListSyntax?
        if let declaration = syntax.as(StructDeclSyntax.self) {
            modifiers = declaration.modifiers
        } else if let declaration = syntax.as(ClassDeclSyntax.self) {
            modifiers = declaration.modifiers
        } else if let declaration = syntax.as(ActorDeclSyntax.self) {
            modifiers = declaration.modifiers
        } else if let declaration = syntax.as(EnumDeclSyntax.self) {
            modifiers = declaration.modifiers
        } else if let declaration = syntax.as(ExtensionDeclSyntax.self) {
            modifiers = declaration.modifiers
        } else {
            return nil
        }
        guard let modifiers else { return .internal }
        let names = modifiers.map { $0.name.text }
        if names.contains("open") { return .public }
        if names.contains("public") { return .public }
        if names.contains("package") { return .package }
        if names.contains("fileprivate") { return .fileprivate }
        if names.contains("private") { return .private }
        return .internal
    }
}
