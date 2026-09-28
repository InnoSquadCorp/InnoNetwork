import Foundation
import InnoNetwork

extension CodeGenerator {
    static let compiledKeywords: Set<String> = [
        "enum", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
        "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties",
    ]

    func needsCompiledSchema(_ schema: Schema, schemas: [String: Schema], visited: Set<String> = []) throws -> Bool {
        if !schema.unsupportedValidationKeywords.isDisjoint(with: Self.compiledKeywords) { return true }
        if let reference = schema.ref {
            let name = try referenceName(reference, schemas: schemas)
            if !visited.contains(name) {
                return try needsCompiledSchema(schemas[name]!, schemas: schemas, visited: visited.union([name]))
            }
        }
        let children =
            Array((schema.properties ?? [:]).values) + (schema.anyOf ?? []) + (schema.items.map { [$0.value] } ?? [])
        for child in children { if try needsCompiledSchema(child, schemas: schemas, visited: visited) { return true } }
        return false
    }

    func renderCompiledSchema(name: String, schema: Schema, schemas: [String: Schema]) throws -> GeneratedFile {
        guard let source = schema.preservedSchema else {
            throw GenerationError.unsupportedSchema("Constrained schemas require the lossless document decoder")
        }
        let definitions = schemas.compactMapValues(\.preservedSchema)
        do { _ = try JSONSchemaPlan(schema: source, definitions: definitions) } catch {
            throw GenerationError.unsupportedSchema("Compiled schema validation failed: \(error)")
        }
        let sourceLiteral = swiftStringLiteralContent(String(decoding: source.data, as: UTF8.self))
        let definitionLiterals = definitions.keys.sorted().map { key in
            "\"\(swiftStringLiteralContent(key))\": try PreservedJSON(data: Data(\"\(swiftStringLiteralContent(String(decoding: definitions[key]!.data, as: UTF8.self)))\".utf8))"
        }.joined(separator: ", ")
        var lines = [
            generatedHeader(comment: "Compiled preserved schema \(name)"), "import Foundation", "import InnoNetwork",
            "public struct \(name): Codable, Sendable, Equatable {",
            "    public let json: PreservedJSON",
            "    private static func plan() throws -> JSONSchemaPlan {",
            "        try JSONSchemaPlan(schema: PreservedJSON(data: Data(\"\(sourceLiteral)\".utf8)), definitions: [\(definitionLiterals.isEmpty ? ":" : definitionLiterals)])",
            "    }",
        ]
        if schema.anyOf != nil { lines.append("    public let matchingBranches: [Int]") }
        lines += ["    public init(json: PreservedJSON) throws {"]
        if schema.anyOf != nil {
            lines.append("        self.matchingBranches = try Self.plan().matchingAlternatives(json)")
        } else {
            lines.append(
                "        guard try Self.plan().matches(json) else { throw JSONProcessingError.noMatchingSchema }")
        }
        lines += [
            "        self.json = json", "    }",
            "    public init(from decoder: any Decoder) throws { try self.init(json: PreservedJSON(from: decoder)) }",
            "    public func encode(to encoder: any Encoder) throws {",
            "        guard try Self.plan().matches(json) else { throw JSONProcessingError.noMatchingSchema }",
            "        try json.encode(to: encoder)", "    }",
        ]
        for (index, branch) in (schema.anyOf ?? []).enumerated() {
            if let reference = branch.ref {
                let type = sanitize(try referenceName(reference, schemas: schemas))
                lines += [
                    "    public func asBranch\(index)() throws -> \(type)? {",
                    "        guard matchingBranches.contains(\(index)) else { return nil }",
                    "        return try PreservedJSONCoding.decode(\(type).self, from: json.data)", "    }",
                ]
            }
        }
        lines.append("}")
        return GeneratedFile(filename: "\(name).swift", contents: lines.joined(separator: "\n") + "\n")
    }
}
