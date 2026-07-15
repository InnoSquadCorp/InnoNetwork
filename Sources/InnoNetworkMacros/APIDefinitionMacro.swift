import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Implements the attached ``APIDefinition`` macro expansion.
public struct APIDefinitionMacro: ExtensionMacro {
    /// Expands `@APIDefinition(method:path:auth:)` into an `APIDefinition`
    /// conformance extension.
    ///
    /// - Parameters:
    ///   - node: Attribute syntax containing the labeled `method:`, `path:`,
    ///     and `auth:` arguments.
    ///   - declaration: Type declaration the macro is attached to.
    ///   - type: Syntax for the annotated type name.
    ///   - protocols: Protocols requested by the compiler for the extension.
    ///   - context: Macro expansion context used by SwiftSyntax.
    /// - Returns: A single extension declaration that synthesizes the
    ///   protocol mechanics not explicitly owned by the annotated struct.
    /// - Throws: ``InnoNetworkMacroDiagnostic`` when required arguments are
    ///   missing, `auth:` is not explicit, `path:` is not a static string
    ///   literal, or a path placeholder does not match a stored property.
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
        let method = methodArgument.expression.trimmedDescription
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
        if let parameterAlias = typeAlias(named: "Parameter", in: declaration),
            isEmptyParameterType(parameterAlias.initializer.value),
            !declaresVariable(named: "parameters", in: declaration),
            properties["body"] == nil,
            properties["query"] == nil
        {
            context.diagnose(
                InnoNetworkMacroDiagnostic(
                    "typealias Parameter = EmptyParameter is redundant; @APIDefinition synthesizes it for empty requests.",
                    id: "api-definition-redundant-empty-parameter",
                    severity: .warning
                ).diagnostic(at: parameterAlias)
            )
        }
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
        witnesses.append("\(accessPrefix)var path: Swift.String { \"\(path)\" }")
        let witnessSource =
            witnesses
            .map {
                $0.split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                    .joined(separator: "\n    ")
            }
            .joined(separator: "\n    ")

        return [
            try ExtensionDeclSyntax(
                """
                extension \(raw: typeName): InnoNetwork.APIDefinition {
                    \(raw: witnessSource)
                }
                """
            )
        ]
    }

    private enum Authentication {
        case anonymous
        case optional
        case required

        var caseName: String {
            switch self {
            case .anonymous: return "anonymous"
            case .optional: return "optional"
            case .required: return "required"
            }
        }
    }

    private static func authentication(from argument: LabeledExprSyntax) throws -> Authentication {
        switch enumCaseName(from: argument.expression) {
        case "anonymous":
            return .anonymous
        case "optional":
            return .optional
        case "required":
            return .required
        default:
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition auth: must be the explicit .anonymous, .optional, or .required enum case.",
                id: "api-definition-invalid-auth"
            ).error(at: argument.expression)
        }
    }

    private static func directAPIDefinitionConformance(
        in declaration: StructDeclSyntax
    ) -> InheritedTypeSyntax? {
        declaration.inheritanceClause?.inheritedTypes.first { inherited in
            let name = inherited.type.trimmedDescription
            return name == "APIDefinition" || name.hasSuffix(".APIDefinition")
        }
    }

    private static func validatePathLiteral(
        _ path: String,
        anchor: some SyntaxProtocol
    ) throws {
        guard !path.contains("?"), !path.contains("#") else {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition path must not contain query or fragment components; declare query values through the query property.",
                id: "api-definition-path-component"
            ).error(at: anchor)
        }

        var index = path.startIndex
        while index < path.endIndex {
            guard path[index] == "%" else {
                index = path.index(after: index)
                continue
            }
            let first = path.index(after: index)
            guard first < path.endIndex else {
                throw invalidPercentEscape(at: anchor)
            }
            let second = path.index(after: first)
            guard second < path.endIndex,
                isASCIIHexDigit(path[first]),
                isASCIIHexDigit(path[second])
            else {
                throw invalidPercentEscape(at: anchor)
            }
            index = path.index(after: second)
        }

        guard !containsDotSegment(path) else {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition path must not contain '.' or '..' segments, including percent-encoded spellings.",
                id: "api-definition-dot-segment"
            ).error(at: anchor)
        }
    }

    private static func containsDotSegment(_ path: String) -> Bool {
        var candidate = path
        // Decode the whole path before splitting each round so encoded `/`
        // separators cannot hide a static traversal segment.
        for _ in 0...path.utf8.count {
            if candidate.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0 == "." || $0 == ".."
            }) {
                return true
            }
            guard let decoded = decodePercentEscapes(candidate), decoded != candidate else { break }
            candidate = decoded
        }
        return false
    }

    private static func decodePercentEscapes(_ value: String) -> String? {
        let input = Array(value.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            guard input[index] == 0x25 else {
                output.append(input[index])
                index += 1
                continue
            }
            guard index + 2 < input.count,
                let high = hexValue(input[index + 1]),
                let low = hexValue(input[index + 2])
            else {
                return nil
            }
            output.append((high << 4) | low)
            index += 3
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    private static func isASCIIHexDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
            let value = character.unicodeScalars.first?.value
        else {
            return false
        }
        switch value {
        case 48...57, 65...70, 97...102:
            return true
        default:
            return false
        }
    }

    private static func invalidPercentEscape(
        at anchor: some SyntaxProtocol
    ) -> DiagnosticsError {
        InnoNetworkMacroDiagnostic(
            "@APIDefinition path contains an invalid percent escape.",
            id: "api-definition-invalid-percent-escape"
        ).error(at: anchor)
    }

    private static func argumentList(from node: AttributeSyntax) throws -> LabeledExprListSyntax {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition requires labeled arguments: method and path.",
                id: "api-definition-missing-arguments"
            ).error(at: node)
        }
        return arguments
    }

    private static func requiredArgument(
        named name: String,
        in arguments: LabeledExprListSyntax
    ) throws -> LabeledExprSyntax {
        guard let argument = arguments.first(where: { $0.label?.text == name }) else {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition requires a \(name): argument.",
                id: "api-definition-missing-\(name)"
            ).error(at: arguments)
        }
        return argument
    }

    private static func stringLiteralArgument(
        named name: String,
        in arguments: LabeledExprListSyntax
    ) throws -> String {
        let argument = try requiredArgument(named: name, in: arguments)
        guard let literal = argument.expression.as(StringLiteralExprSyntax.self) else {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition \(name): must be a static string literal.",
                id: "api-definition-nonliteral-\(name)"
            ).error(at: argument.expression)
        }

        var value = ""
        for segment in literal.segments {
            guard let stringSegment = segment.as(StringSegmentSyntax.self) else {
                let fixIts = interpolationToPlaceholderFixIts(segment)
                throw InnoNetworkMacroDiagnostic(
                    "@APIDefinition \(name): does not support string interpolation.",
                    id: "api-definition-interpolated-\(name)"
                ).error(at: segment, fixIts: fixIts)
            }
            value += stringSegment.content.text
        }
        return value
    }

    /// Produces a machine-applicable FixIt that rewrites a single-identifier
    /// interpolation segment (`\(foo)`) into the `{foo}` placeholder syntax
    /// that the macro understands. Non-trivial interpolations (member access,
    /// expressions, multiple arguments) deliberately have no FixIt — the
    /// fix is not mechanically obvious, and emitting a wrong suggestion is
    /// worse than asking the author to rewrite by hand.
    private static func interpolationToPlaceholderFixIts(
        _ segment: StringLiteralSegmentListSyntax.Element
    ) -> [FixIt] {
        guard let expressionSegment = segment.as(ExpressionSegmentSyntax.self),
            expressionSegment.expressions.count == 1,
            let onlyExpression = expressionSegment.expressions.first,
            onlyExpression.label == nil,
            let identifier = onlyExpression.expression.as(DeclReferenceExprSyntax.self)?
                .baseName.text
        else {
            return []
        }
        let replacement = StringSegmentSyntax(
            content: .stringSegment("{\(identifier)}")
        )
        return [
            FixIt(
                message: InnoNetworkMacroFixItMessage(
                    "Replace string interpolation with '{\(identifier)}' path placeholder.",
                    id: "api-definition-replace-interpolation"
                ),
                changes: [
                    .replace(
                        oldNode: Syntax(segment),
                        newNode: Syntax(replacement)
                    )
                ]
            )
        ]
    }

    private struct StoredProperty {
        let isOptional: Bool
        let typeKind: TypeKind
        let type: TypeSyntax?
    }

    /// Coarse classification of a stored property's declared type, used by
    /// path placeholder validation. The macro only inspects syntax, so any
    /// classification more precise than this requires the type checker.
    private enum TypeKind {
        case concrete
        case opaque
        case genericParameter
    }

    private static func hasCompleteManualPayloadContract(
        in declaration: some DeclGroupSyntax
    ) -> Bool {
        typeAlias(named: "Parameter", in: declaration) != nil
            && instanceVariable(named: "parameters", in: declaration) != nil
    }

    private static func validateSimplePayloadDeclarations(
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

    /// Simple mode can only map identifier-named stored values to path and
    /// payload roles. Reject destructuring up front so tuple-bound values do
    /// not disappear from the generated request without a diagnostic.
    private static func validateSimpleStoredPropertyPatterns(
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

    /// Simple mode is deliberately fail-closed: every stored value must be
    /// part of the route, the inferred payload, or an explicit endpoint
    /// witness. Without this check a misspelled `body`/`query` property still
    /// compiles while the generated request silently drops the value.
    private static func validateEveryStoredPropertyIsConsumed(
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
                    "@APIDefinition stored property '\(identifier)' is not used by the route or inferred payload. In simple mode place GET values in 'query' and non-GET values in 'body', or declare a complete Parameter + parameters fallback.",
                    id: "api-definition-unused-stored-property"
                ).error(at: binding.pattern)
            }
        }
    }

    private static func storedProperties(in declaration: some DeclGroupSyntax) -> [String: StoredProperty] {
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

    private static func payloadWitnesses(
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

        // A complete manual pair is the advanced escape hatch. Once present,
        // it is authoritative even when the endpoint also stores values named
        // `body` or `query` for its own computed witnesses.
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

    private static func isEmptyParameterType(_ type: TypeSyntax) -> Bool {
        let source = type.trimmedDescription
        return source == "EmptyParameter" || source == "InnoNetwork.EmptyParameter"
    }

    private enum MethodKind {
        case queryOnly(name: String)
        case body
        case requiresExplicitPayload
    }

    private static func methodKind(_ method: ExprSyntax) -> MethodKind {
        switch enumCaseName(from: method) {
        case "get":
            return .queryOnly(name: "GET")
        case "head":
            return .queryOnly(name: "HEAD")
        case "post", "put", "patch", "delete":
            return .body
        default:
            return .requiresExplicitPayload
        }
    }

    private static let simplePayloadMethodDiagnostic =
        "@APIDefinition simple body/query inference requires method: to be an explicit .get, .head, .post, .put, .patch, or .delete standard HTTPMethod member; use a complete Parameter + parameters fallback for OPTIONS, CONNECT, TRACE, custom, or dynamic methods."

    private static func enumCaseName(from expression: ExprSyntax) -> String? {
        expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
    }

    private static func normalizedParametersWitness(
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

    private static func parameterTypeName(
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

    private static func typeAlias(
        named name: String,
        in declaration: some DeclGroupSyntax
    ) -> TypeAliasDeclSyntax? {
        declaration.memberBlock.members.lazy.compactMap { member in
            member.decl.as(TypeAliasDeclSyntax.self)
        }.first { $0.name.text == name }
    }

    private static func declaresTypeAlias(
        named name: String,
        in declaration: some DeclGroupSyntax
    ) -> Bool {
        typeAlias(named: name, in: declaration) != nil
    }

    private static func declaresVariable(
        named name: String,
        in declaration: some DeclGroupSyntax
    ) -> Bool {
        variableBinding(named: name, in: declaration) != nil
    }

    private static func instanceVariable(
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

    private static func variableBinding(
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

    private static func isEligibleStoredInstanceProperty(
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

    private static func hasNonInstanceModifier(_ variable: VariableDeclSyntax) -> Bool {
        variable.modifiers.contains { modifier in
            switch modifier.name.text {
            case "static", "class", "lazy":
                return true
            default:
                return false
            }
        }
    }

    /// Returns the syntactic generic parameter names visible to the
    /// declaration the macro is attached to. This includes parameters
    /// declared directly on the host type (e.g. `T`, `Element`) plus any
    /// declared on enclosing types — when a `@APIDefinition` struct is
    /// nested inside `Container<T>`, the inner type's path placeholders
    /// must reject references to the parent's `T` for the same reason
    /// they reject the host type's own generics: the encoder requires a
    /// concrete `LosslessStringConvertible & Sendable` type and the macro
    /// cannot resolve generic constraints at expansion time.
    private static func genericParameterNames(in declaration: some DeclGroupSyntax) -> Set<String> {
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

    private static func genericParameters(on syntax: Syntax) -> [String] {
        let clause: GenericParameterClauseSyntax?
        if let declaration = syntax.as(StructDeclSyntax.self) {
            clause = declaration.genericParameterClause
        } else if let declaration = syntax.as(ClassDeclSyntax.self) {
            clause = declaration.genericParameterClause
        } else if let declaration = syntax.as(ActorDeclSyntax.self) {
            clause = declaration.genericParameterClause
        } else if let declaration = syntax.as(EnumDeclSyntax.self) {
            clause = declaration.genericParameterClause
        } else if let declaration = syntax.as(ExtensionDeclSyntax.self) {
            // Extensions cannot themselves declare generic parameters,
            // but if the macro is somehow attached on one we still want
            // to walk further up rather than terminate the search.
            _ = declaration
            clause = nil
        } else {
            clause = nil
        }
        guard let clause else { return [] }
        return clause.parameters.map { $0.name.text }
    }

    /// Syntactic classification. Returns `.opaque` for `some X` types,
    /// `.genericParameter` when the type is a bare identifier that matches a
    /// generic parameter on the enclosing declaration, and `.concrete`
    /// otherwise. Limitations:
    /// - `nil` (inferred-type bindings) is reported as `.concrete` so that
    ///   inference-via-initializer keeps working; the compiler still
    ///   enforces the `LosslessStringConvertible & Sendable` constraint on
    ///   the generated `percentEncodedSegment` call site.
    /// - Aliases that resolve to a generic parameter (e.g. `typealias U = T`)
    ///   are not detected — only direct references to the parameter name are.
    private static func classifyType(
        _ type: TypeSyntax?,
        genericParameters: Set<String>
    ) -> TypeKind {
        guard let type else { return .concrete }
        // `some X` and `any X` share the same syntax node; reject only
        // `some` because `any X` (where `X: LosslessStringConvertible`)
        // is a legitimate existential the encoder can still consume.
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

    /// Best-effort detection of whether a stored property is declared optional.
    ///
    /// Limitation: when `type` is `nil` (e.g. inferred-type bindings such as
    /// `let value = expression`) we conservatively return `false`. The macro
    /// only inspects syntactic types, so optional inference through a typealias
    /// expansion or a generic placeholder is not detected — placeholders that
    /// rely on those forms must be declared with explicit optional syntax to
    /// be recognized.
    private static func isOptionalType(_ type: TypeSyntax?) -> Bool {
        guard let type else { return false }
        if type.is(OptionalTypeSyntax.self) || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return true
        }
        let normalized = String(type.trimmedDescription.filter { $0 != " " })
        return normalized.hasPrefix("Optional<") || normalized.hasPrefix("Swift.Optional<")
    }

    /// Returns the access-control keyword that the generated extension
    /// members should carry, mirroring the visibility of the attached
    /// declaration.
    ///
    /// The earlier implementation returned an empty string for any type
    /// that did not carry `public`/`open`/`package` modifiers. That is
    /// *almost* equivalent to `internal` — Swift defaults to internal —
    /// but the silent default has two failure modes: (1) when the
    /// extension is generated into a context that imports the module
    /// without `@testable`, callers cannot see why the witness members
    /// are reachable, and (2) a future refactor that switches the
    /// attached type to `fileprivate` would leave a stale `internal`
    /// witness in the generated extension with no surfaced warning.
    /// Emit the keyword explicitly so the generated source is
    /// self-describing and any visibility narrowing on the host type
    /// has to be propagated by the author rather than silently kept
    /// at internal by the macro.
    private static func witnessAccessPrefix(in declaration: some DeclGroupSyntax) -> String {
        // A nested type's effective visibility is bounded by the
        // visibility of every enclosing type — `public struct Inner`
        // declared inside `internal struct Outer` is effectively
        // internal because nobody outside the module can reach the
        // outer name. Generate the witness at the tightest visibility
        // along the chain so the extension does not advertise a wider
        // surface than the host type can be referenced through.
        let levels = collectVisibilityLevels(from: Syntax(declaration))
        let effective =
            levels.first.map { first in
                levels.dropFirst().reduce(first) { min($0, $1) }
            } ?? .internal
        return effective.witnessPrefix
    }

    private enum VisibilityLevel: Int, Comparable {
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
                // `private` on a top-level type behaves like
                // `fileprivate`; mirror that on the witness rather than
                // silently widening visibility to `internal`.
                return "fileprivate "
            }
        }
    }

    private static func collectVisibilityLevels(from syntax: Syntax) -> [VisibilityLevel] {
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

    private static func visibilityLevel(of syntax: Syntax) -> VisibilityLevel? {
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
        // `open` only widens classes; struct/extension members map to
        // `public` for witness emission purposes.
        if names.contains("open") { return .public }
        if names.contains("public") { return .public }
        if names.contains("package") { return .package }
        if names.contains("fileprivate") { return .fileprivate }
        if names.contains("private") { return .private }
        return .internal
    }

    private static func interpolatedPath(
        _ path: String,
        properties: [String: StoredProperty],
        usedProperties: inout Set<String>,
        anchor: some SyntaxProtocol
    ) throws -> String {
        var result = ""
        var index = path.startIndex
        while index < path.endIndex {
            let character = path[index]
            if character == "{" {
                guard let close = path[index...].firstIndex(of: "}") else {
                    throw InnoNetworkMacroDiagnostic(
                        "@APIDefinition path contains an unterminated placeholder.",
                        id: "api-definition-unterminated-placeholder"
                    ).error(at: anchor)
                }
                let nameStart = path.index(after: index)
                let name = String(path[nameStart..<close])
                guard !name.isEmpty, let property = properties[name] else {
                    throw InnoNetworkMacroDiagnostic(
                        "@APIDefinition path placeholder {\(name)} must match a stored property.",
                        id: "api-definition-unknown-placeholder"
                    ).error(at: anchor)
                }
                if property.isOptional {
                    throw InnoNetworkMacroDiagnostic(
                        "@APIDefinition path placeholder {\(name)} cannot reference an Optional stored property.",
                        id: "api-definition-optional-placeholder"
                    ).error(at: anchor)
                }
                switch property.typeKind {
                case .opaque:
                    throw InnoNetworkMacroDiagnostic(
                        "@APIDefinition path placeholder {\(name)} cannot reference an opaque (`some`) type. Declare the property with a concrete `LosslessStringConvertible & Sendable` type.",
                        id: "api-definition-opaque-placeholder"
                    ).error(at: anchor)
                case .genericParameter:
                    throw InnoNetworkMacroDiagnostic(
                        "@APIDefinition path placeholder {\(name)} cannot reference a generic parameter. Declare the property with a concrete `LosslessStringConvertible & Sendable` type.",
                        id: "api-definition-generic-placeholder"
                    ).error(at: anchor)
                case .concrete:
                    break
                }
                usedProperties.insert(name)
                result += "\\(InnoNetwork.EndpointPathEncoding.percentEncodedSegment(\(name)))"
                index = path.index(after: close)
            } else if character == "}" {
                throw InnoNetworkMacroDiagnostic(
                    "@APIDefinition path contains an unmatched closing brace.",
                    id: "api-definition-unmatched-placeholder"
                ).error(at: anchor)
            } else {
                result.append(character)
                index = path.index(after: index)
            }
        }
        return result
    }
}
