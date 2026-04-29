import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct APIDefinitionMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let arguments = try argumentList(from: node)
        let method = try requiredArgument(named: "method", in: arguments).expression.trimmedDescription
        let pathLiteral = try stringLiteralArgument(named: "path", in: arguments)
        let properties = storedPropertyNames(in: declaration)
        let path = try interpolatedPath(pathLiteral, properties: properties)
        let typeName = type.trimmedDescription

        return [
            try ExtensionDeclSyntax(
                """
                extension \(raw: typeName): APIDefinition {
                    public typealias Parameter = EmptyParameter
                    public var method: HTTPMethod { \(raw: method) }
                    public var path: String { "\(raw: path)" }
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
            )
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
            )
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
            )
        }

        var value = ""
        for segment in literal.segments {
            guard let stringSegment = segment.as(StringSegmentSyntax.self) else {
                throw InnoNetworkMacroDiagnostic(
                    "@APIDefinition \(name): does not support string interpolation.",
                    id: "api-definition-interpolated-\(name)"
                )
            }
            value += stringSegment.content.text
        }
        return value
    }

    private static func storedPropertyNames(in declaration: some DeclGroupSyntax) -> Set<String> {
        var names: Set<String> = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in variable.bindings {
                guard binding.accessorBlock == nil,
                    let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                else {
                    continue
                }
                names.insert(identifier)
            }
        }
        return names
    }

    private static func interpolatedPath(_ path: String, properties: Set<String>) throws -> String {
        var result = ""
        var index = path.startIndex
        while index < path.endIndex {
            let character = path[index]
            if character == "{" {
                guard let close = path[index...].firstIndex(of: "}") else {
                    throw InnoNetworkMacroDiagnostic(
                        "@APIDefinition path contains an unterminated placeholder.",
                        id: "api-definition-unterminated-placeholder"
                    )
                }
                let nameStart = path.index(after: index)
                let name = String(path[nameStart..<close])
                guard !name.isEmpty, properties.contains(name) else {
                    throw InnoNetworkMacroDiagnostic(
                        "@APIDefinition path placeholder {\(name)} must match a stored property.",
                        id: "api-definition-unknown-placeholder"
                    )
                }
                result += "\\(\(name))"
                index = path.index(after: close)
            } else if character == "}" {
                throw InnoNetworkMacroDiagnostic(
                    "@APIDefinition path contains an unmatched closing brace.",
                    id: "api-definition-unmatched-placeholder"
                )
            } else {
                result.append(character)
                index = path.index(after: index)
            }
        }
        return result
    }
}
