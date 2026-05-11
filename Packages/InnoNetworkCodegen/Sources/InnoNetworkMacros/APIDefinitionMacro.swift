import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Implements the attached ``APIDefinition`` macro expansion.
public struct APIDefinitionMacro: ExtensionMacro {
    /// Expands `@APIDefinition(method:path:)` into an `APIDefinition`
    /// conformance extension.
    ///
    /// - Parameters:
    ///   - node: Attribute syntax containing the labeled `method:` and
    ///     `path:` arguments.
    ///   - declaration: Type declaration the macro is attached to.
    ///   - type: Syntax for the annotated type name.
    ///   - protocols: Protocols requested by the compiler for the extension.
    ///   - context: Macro expansion context used by SwiftSyntax.
    /// - Returns: A single extension declaration that synthesizes
    ///   `Parameter`, `method`, and `path`.
    /// - Throws: ``InnoNetworkMacroDiagnostic`` when required arguments are
    ///   missing, `path:` is not a static string literal, or a path placeholder
    ///   does not match a stored property.
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let arguments = try argumentList(from: node)
        let method = try requiredArgument(named: "method", in: arguments).expression.trimmedDescription
        let pathArgument = try requiredArgument(named: "path", in: arguments)
        let pathLiteral = try stringLiteralArgument(named: "path", in: arguments)
        let properties = storedProperties(in: declaration)
        let path = try interpolatedPath(pathLiteral, properties: properties, anchor: pathArgument.expression)
        let typeName = type.trimmedDescription
        let accessPrefix = witnessAccessPrefix(in: declaration)

        return [
            try ExtensionDeclSyntax(
                """
                extension \(raw: typeName): APIDefinition {
                    \(raw: accessPrefix)typealias Parameter = EmptyParameter
                    \(raw: accessPrefix)var method: HTTPMethod { \(raw: method) }
                    \(raw: accessPrefix)var path: String { "\(raw: path)" }
                }
                """
            )
        ]
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
    }

    /// Coarse classification of a stored property's declared type, used by
    /// path placeholder validation. The macro only inspects syntax, so any
    /// classification more precise than this requires the type checker.
    private enum TypeKind {
        case concrete
        case opaque
        case genericParameter
    }

    private static func storedProperties(in declaration: some DeclGroupSyntax) -> [String: StoredProperty] {
        let genericParameters = genericParameterNames(in: declaration)
        var properties: [String: StoredProperty] = [:]
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in variable.bindings {
                guard binding.accessorBlock == nil,
                    let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                else {
                    continue
                }
                let type = binding.typeAnnotation?.type
                properties[identifier] = StoredProperty(
                    isOptional: isOptionalType(type),
                    typeKind: classifyType(type, genericParameters: genericParameters)
                )
            }
        }
        return properties
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
        if type.is(SomeOrAnyTypeSyntax.self) {
            // `some X` and `any X` share the same syntax node; reject only
            // `some` because `any X` (where `X: LosslessStringConvertible`)
            // is a legitimate existential the encoder can still consume.
            if let constrained = type.as(SomeOrAnyTypeSyntax.self),
                constrained.someOrAnySpecifier.text == "some"
            {
                return .opaque
            }
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
        let effective = levels.reduce(VisibilityLevel.internal) { min($0, $1) }
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
