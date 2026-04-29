import Foundation
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
        let arguments = node.arguments?.description ?? ""
        let method = argument(named: "method", in: arguments) ?? ".get"
        let rawPath = stringArgument(named: "path", in: arguments) ?? "/"
        let properties = storedPropertyNames(in: declaration.description)
        let path = interpolatedPath(rawPath, properties: properties)
        let typeName = type.description.trimmingCharacters(in: .whitespacesAndNewlines)

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

    private static func argument(named name: String, in arguments: String) -> String? {
        let pattern = "\(name)\\s*:\\s*([^,\\)]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: arguments, range: NSRange(arguments.startIndex..., in: arguments)),
            let range = Range(match.range(at: 1), in: arguments)
        else {
            return nil
        }
        return String(arguments[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stringArgument(named name: String, in arguments: String) -> String? {
        let pattern = "\(name)\\s*:\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: arguments, range: NSRange(arguments.startIndex..., in: arguments)),
            let range = Range(match.range(at: 1), in: arguments)
        else {
            return nil
        }
        return String(arguments[range])
    }

    private static func storedPropertyNames(in declaration: String) -> Set<String> {
        let pattern = "\\b(?:let|var)\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*:"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(declaration.startIndex..., in: declaration)
        return Set(
            regex.matches(in: declaration, range: range).compactMap { match in
                guard let range = Range(match.range(at: 1), in: declaration) else { return nil }
                return String(declaration[range])
            }
        )
    }

    private static func interpolatedPath(_ path: String, properties: Set<String>) -> String {
        var result = path
        for property in properties {
            result = result.replacingOccurrences(of: "{\(property)}", with: "\\(\(property))")
        }
        return result
    }
}
