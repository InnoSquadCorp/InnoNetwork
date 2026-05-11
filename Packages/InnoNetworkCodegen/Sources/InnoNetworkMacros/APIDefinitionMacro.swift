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
                throw InnoNetworkMacroDiagnostic(
                    "@APIDefinition \(name): does not support string interpolation.",
                    id: "api-definition-interpolated-\(name)"
                ).error(at: segment)
            }
            value += stringSegment.content.text
        }
        return value
    }

    private struct StoredProperty {
        let isOptional: Bool
    }

    private static func storedProperties(in declaration: some DeclGroupSyntax) -> [String: StoredProperty] {
        var properties: [String: StoredProperty] = [:]
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in variable.bindings {
                guard binding.accessorBlock == nil,
                    let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                else {
                    continue
                }
                properties[identifier] = StoredProperty(isOptional: isOptionalType(binding.typeAnnotation?.type))
            }
        }
        return properties
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
        let modifiers = declarationModifiers(in: declaration)
        if modifiers.contains(where: { $0 == "open" }) {
            // `open` cannot apply to struct members or extension methods
            // in the same way it does to a class declaration; the
            // strongest correctly-applicable witness modifier is
            // `public`.
            return "public "
        }
        if modifiers.contains("public") {
            return "public "
        }
        if modifiers.contains("package") {
            return "package "
        }
        if modifiers.contains("fileprivate") {
            return "fileprivate "
        }
        if modifiers.contains("private") {
            // `private` on a top-level type behaves like `fileprivate`;
            // mirror that on the witness rather than silently widening
            // visibility to `internal`.
            return "fileprivate "
        }
        return "internal "
    }

    private static func declarationModifiers(in declaration: some DeclGroupSyntax) -> [String] {
        let syntax = Syntax(declaration)
        let modifiers: DeclModifierListSyntax?
        if let declaration = syntax.as(StructDeclSyntax.self) {
            modifiers = declaration.modifiers
        } else if let declaration = syntax.as(ClassDeclSyntax.self) {
            modifiers = declaration.modifiers
        } else if let declaration = syntax.as(ActorDeclSyntax.self) {
            modifiers = declaration.modifiers
        } else if let declaration = syntax.as(EnumDeclSyntax.self) {
            modifiers = declaration.modifiers
        } else {
            modifiers = nil
        }
        return modifiers?.map { $0.name.text } ?? []
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
