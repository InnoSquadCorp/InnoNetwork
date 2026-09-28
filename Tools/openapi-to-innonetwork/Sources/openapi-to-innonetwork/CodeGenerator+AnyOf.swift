import Foundation

extension CodeGenerator {
    /// Validation IR is intentionally narrower than ordinary serialization codegen.
    /// Never normalize away a constraint before checking it here.
    func validationLiteral(
        _ schema: Schema, schemas: [String: Schema], visiting: Set<String> = [],
        depth: Int = 0, work: inout Int
    ) throws -> String {
        work += 1
        guard depth < 32, work <= 4096 else {
            throw GenerationError.unsupportedSchema("anyOf validation graph exceeds depth/node limits")
        }
        guard schema.unsupportedValidationKeywords.isEmpty else {
            throw GenerationError.unsupportedSchema(
                "anyOf cannot validate keywords: \(schema.unsupportedValidationKeywords.sorted().joined(separator: ", "))"
            )
        }
        guard schema.format == nil, schema.allOf == nil, schema.oneOf == nil, schema.discriminator == nil else {
            throw GenerationError.unsupportedSchema(
                "anyOf validation does not support format, allOf, oneOf or discriminator constraints")
        }
        if let reference = schema.ref {
            guard schema.type == nil, schema.properties == nil, schema.required == nil, schema.items == nil,
                schema.nullable == nil, schema.anyOf == nil, schema.additionalProperties == nil
            else {
                throw GenerationError.unsupportedSchema("anyOf validation rejects $ref siblings")
            }
            let name = try referenceName(reference, schemas: schemas)
            guard !visiting.contains(name) else {
                throw GenerationError.unsupportedSchema("Recursive anyOf validation reference: \(name)")
            }
            return try validationLiteral(
                schemas[name]!, schemas: schemas, visiting: visiting.union([name]),
                depth: depth + 1, work: &work)
        }
        if let branches = schema.anyOf {
            try validateAnyOfShape(schema)
            let children = try branches.map {
                try validationLiteral($0, schemas: schemas, visiting: visiting, depth: depth + 1, work: &work)
            }
            return ".anyOf([\(children.joined(separator: ", "))])"
        }
        let literal: String
        switch schema.type {
        case "object":
            guard schema.items == nil else {
                throw GenerationError.unsupportedSchema("Object with array constraints in anyOf")
            }
            let required = schema.required ?? []
            guard Set(required).count == required.count else {
                throw GenerationError.unsupportedSchema("Duplicate required property in anyOf")
            }
            work += required.reduce(0) { $0 + $1.utf8.count + 1 }
            let properties = try (schema.properties ?? [:]).sorted(by: { $0.key < $1.key }).map { name, child in
                guard name.utf8.count <= 1024 else {
                    throw GenerationError.unsupportedSchema("anyOf property name too long")
                }
                work += name.utf8.count + 1
                let value = try validationLiteral(
                    child, schemas: schemas, visiting: visiting, depth: depth + 1, work: &work)
                return "\"\(swiftStringLiteralContent(name))\": \(value)"
            }
            guard required.allSatisfy({ $0.utf8.count <= 1024 }), required.count <= 4096, work <= 4096 else {
                throw GenerationError.unsupportedSchema("anyOf required property list too large")
            }
            let members = properties.isEmpty ? "[:]" : "[\(properties.joined(separator: ", "))]"
            let names = required.sorted().map { "\"\(swiftStringLiteralContent($0))\"" }.joined(separator: ", ")
            literal =
                ".object(properties: \(members), required: [\(names)], allowsAdditionalProperties: \(schema.additionalProperties != false))"
        case "array":
            guard let items = schema.items, schema.properties == nil, schema.required == nil,
                schema.additionalProperties == nil
            else {
                throw GenerationError.unsupportedSchema(
                    "anyOf arrays require one item schema and no object constraints")
            }
            literal =
                ".array(items: \(try validationLiteral(items.value, schemas: schemas, visiting: visiting, depth: depth + 1, work: &work)))"
        case "string", "number", "integer", "boolean":
            guard schema.items == nil, schema.properties == nil, schema.required == nil,
                schema.additionalProperties == nil
            else {
                throw GenerationError.unsupportedSchema("anyOf scalar has container constraints")
            }
            literal = ".\(schema.type!)"
        default:
            throw GenerationError.unsupportedSchema("anyOf validation requires an explicit supported type")
        }
        return schema.nullable == true ? ".nullable(\(literal))" : literal
    }

    func validateAnyOfShape(_ schema: Schema) throws {
        guard let branches = schema.anyOf, (2...32).contains(branches.count),
            schema.ref == nil, schema.type == nil, schema.properties == nil, schema.required == nil,
            schema.items == nil, schema.nullable == nil, schema.additionalProperties == nil,
            schema.allOf == nil, schema.oneOf == nil, schema.format == nil, schema.discriminator == nil,
            schema.unsupportedValidationKeywords.isEmpty,
            branches.allSatisfy({ $0.ref != nil }), Set(branches.compactMap(\.ref)).count == branches.count
        else {
            throw GenerationError.unsupportedSchema(
                "anyOf requires 2...32 distinct named local references without validation siblings")
        }
    }

    func renderAnyOf(name: String, schema: Schema, schemas: [String: Schema]) throws -> GeneratedFile {
        try validateAnyOfShape(schema)
        var work = 0
        // Inspect the unnormalized graph, including every optional property.
        _ = try validationLiteral(schema, schemas: schemas, work: &work)
        var literals: [String] = []
        for branch in schema.anyOf! {
            var branchWork = 0
            literals.append(try validationLiteral(branch, schemas: schemas, work: &branchWork))
        }
        var lines = [
            generatedHeader(comment: "Preserved anyOf schema \(name)"), "import Foundation", "import InnoNetwork",
            "public struct \(name): Codable, Sendable, Equatable {",
            "    public let json: PreservedJSON",
            "    public let matchingBranches: [Int]",
            "    private static let schemas: [JSONSchema] = [\(literals.joined(separator: ", "))]",
            "    public init(json: PreservedJSON) throws {",
            "        self.matchingBranches = try JSONSchema.matchingAlternatives(Self.schemas, document: json)",
            "        self.json = json", "    }",
            "    public init(from decoder: any Decoder) throws {",
            "        try self.init(json: PreservedJSON(from: decoder))", "    }",
            "    public func encode(to encoder: any Encoder) throws {",
            "        _ = try JSONSchema.matchingAlternatives(Self.schemas, document: json)",
            "        try json.encode(to: encoder)", "    }",
        ]
        for (index, branch) in schema.anyOf!.enumerated() {
            let type = sanitize(try referenceName(branch.ref!, schemas: schemas))
            lines += [
                "    public func asBranch\(index)() throws -> \(type)? {",
                "        guard matchingBranches.contains(\(index)) else { return nil }",
                "        return try PreservedJSONCoding.decode(\(type).self, from: json.data)", "    }",
            ]
        }
        lines.append("}")
        return GeneratedFile(filename: "\(name).swift", contents: lines.joined(separator: "\n") + "\n")
    }

    func containsAnyOf(_ schema: Schema, schemas: [String: Schema], visited: Set<String> = []) throws -> Bool {
        if schema.anyOf != nil { return true }
        if let reference = schema.ref {
            let name = try referenceName(reference, schemas: schemas)
            if !visited.contains(name) {
                return try containsAnyOf(schemas[name]!, schemas: schemas, visited: visited.union([name]))
            }
        }
        let children =
            Array((schema.properties ?? [:]).values) + (schema.allOf ?? []) + (schema.oneOf ?? [])
            + (schema.items.map { [$0.value] } ?? [])
        for child in children {
            if try containsAnyOf(child, schemas: schemas, visited: visited) { return true }
        }
        return false
    }
}
