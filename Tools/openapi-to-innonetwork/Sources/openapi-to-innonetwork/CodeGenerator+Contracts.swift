import Foundation

extension CodeGenerator {
    func validateAliasChain(name: String, schemas: [String: Schema]) throws {
        var seen: Set<String> = [name]
        var current = name
        while let reference = schemas[current]?.ref {
            current = try referenceName(reference, schemas: schemas)
            guard seen.insert(current).inserted else {
                throw GenerationError.unsupportedSchema("Cyclic component alias: \(current)")
            }
        }
    }

    func authentication(for requirements: [[String: [String]]]?, schemes: [String: SecurityScheme]) throws -> String {
        try SecurityIR(requirements: requirements, schemes: schemes).legacySessionAuthentication()
    }

    func bindPath(_ path: String, inherited: [PathParameter], operation: [PathParameter]) throws
        -> (literal: String, arguments: [(name: String, type: String)])
    {
        var parameters: [String: PathParameter] = [:]
        for level in [inherited, operation] {
            var seen: Set<String> = []
            for parameter in level {
                guard parameter.in == "path", seen.insert(parameter.name).inserted else {
                    throw GenerationError.unsupportedPath(
                        "Only unique path parameters are supported: \(parameter.name)")
                }
                parameters[parameter.name] = parameter
            }
        }
        var literal = ""
        var arguments: [(name: String, type: String)] = []
        var bound: Set<String> = []
        var identifiers: Set<String> = []
        var index = path.startIndex
        while index < path.endIndex {
            if path[index] == "{" {
                guard let end = path[index...].firstIndex(of: "}") else {
                    throw GenerationError.unsupportedPath("Unclosed placeholder in \(path)")
                }
                let name = String(path[path.index(after: index)..<end])
                guard !name.isEmpty, !name.contains("/"), !name.contains("{"),
                    let parameter = parameters[name], parameter.required == true,
                    parameter.style == nil || parameter.style == "simple",
                    parameter.explode != true, let schema = parameter.schema,
                    schema.ref == nil, schema.nullable != true,
                    schema.allOf == nil, schema.oneOf == nil, schema.anyOf == nil,
                    ["string", "integer", "boolean"].contains(schema.type ?? ""),
                    schema.format == nil || ["int32", "int64", "uuid"].contains(schema.format!)
                else {
                    throw GenerationError.unsupportedPath(
                        "Unsupported or undeclared {\(name)} in \(path); declare a required simple scalar path parameter"
                    )
                }
                let identifier = "path_" + safeIdentifier(name)
                if bound.insert(name).inserted {
                    guard identifiers.insert(identifier).inserted else {
                        throw GenerationError.namingCollision("Path parameter names map to \(identifier)")
                    }
                    arguments.append((identifier, swiftTypeName(for: schema, fallback: nil)!))
                }
                literal += "\\(EndpointPathEncoding.percentEncodedSegment(\(identifier)))"
                index = path.index(after: end)
            } else {
                guard path[index] != "}", path[index] != "?", path[index] != "#" else {
                    throw GenerationError.unsupportedPath("Invalid path literal \(path)")
                }
                literal += swiftStringLiteralContent(String(path[index]))
                index = path.index(after: index)
            }
        }
        guard bound == Set(parameters.keys) else {
            throw GenerationError.unsupportedPath("Path parameters do not match placeholders in \(path)")
        }
        return (literal, arguments)
    }

    func referenceName(_ reference: String, schemas: [String: Schema]) throws -> String {
        let prefix = "#/components/schemas/"
        guard reference.hasPrefix(prefix) else {
            throw GenerationError.unsupportedSchema("Only local schema references are supported: \(reference)")
        }
        let name = String(reference.dropFirst(prefix.count)).replacingOccurrences(of: "~1", with: "/")
            .replacingOccurrences(of: "~0", with: "~")
        guard schemas[name] != nil else { throw GenerationError.unsupportedSchema("Missing schema \(name)") }
        return name
    }

    func normalizedSchema(_ schema: Schema, schemas: [String: Schema], expanding: Set<String>) throws -> Schema {
        guard schema.anyOf == nil else {
            throw GenerationError.unsupportedSchema("anyOf is ambiguous; use a named discriminated oneOf")
        }
        if let reference = schema.ref { _ = try referenceName(reference, schemas: schemas) }
        if schema.oneOf != nil {
            guard schema.discriminator != nil, schema.allOf == nil, schema.properties == nil else {
                throw GenerationError.unsupportedSchema(
                    "oneOf requires a discriminator and cannot mix object/allOf siblings")
            }
        }
        var result = schema
        if let branches = schema.allOf {
            guard !branches.isEmpty, schema.ref == nil, schema.oneOf == nil,
                schema.type == nil || schema.type == "object"
            else { throw GenerationError.unsupportedSchema("allOf supports object branches only") }
            var properties = schema.properties ?? [:]
            var required = Set(schema.required ?? [])
            for branch in branches {
                var expanded = branch
                var visited = expanding
                if let reference = branch.ref {
                    let name = try referenceName(reference, schemas: schemas)
                    guard visited.insert(name).inserted else {
                        throw GenerationError.unsupportedSchema("Cyclic allOf: \(name)")
                    }
                    expanded = schemas[name]!
                }
                let normalized = try normalizedSchema(expanded, schemas: schemas, expanding: visited)
                guard normalized.ref == nil, normalized.oneOf == nil, normalized.nullable != true,
                    normalized.type == "object" || (normalized.type == nil && normalized.properties != nil)
                else { throw GenerationError.unsupportedSchema("allOf branch is not an object") }
                for (name, value) in normalized.properties ?? [:] {
                    if let previous = properties[name], previous != value {
                        throw GenerationError.unsupportedSchema("Conflicting allOf property \(name)")
                    }
                    properties[name] = value
                }
                required.formUnion(normalized.required ?? [])
            }
            result.type = "object"
            result.properties = properties
            result.required = required.sorted()
            result.allOf = nil
        }
        for property in (result.properties ?? [:]).values {
            guard property.allOf == nil, property.oneOf == nil, property.anyOf == nil else {
                throw GenerationError.unsupportedSchema(
                    "Inline compositions must be named components referenced with $ref")
            }
            _ = try normalizedSchema(property, schemas: schemas, expanding: expanding)
        }
        if let item = result.items?.value {
            guard item.allOf == nil, item.oneOf == nil, item.anyOf == nil, item.nullable != true else {
                throw GenerationError.unsupportedSchema(
                    "Array composition/nullable items require an application-owned model")
            }
            _ = try normalizedSchema(item, schemas: schemas, expanding: expanding)
        }
        return result
    }

    func renderUnion(name: String, schema: Schema, schemas: [String: Schema]) throws -> GeneratedFile {
        guard let branches = schema.oneOf, branches.count >= 2, let discriminator = schema.discriminator,
            schema.nullable != true
        else { throw GenerationError.unsupportedSchema("A discriminated oneOf requires at least two branches") }
        var variants: [(tag: String, type: String, property: String)] = []
        var seenTags: Set<String> = []
        var references: Set<String> = []
        for branch in branches {
            guard let reference = branch.ref else {
                throw GenerationError.unsupportedSchema("oneOf branches must be local references")
            }
            let component = try referenceName(reference, schemas: schemas)
            guard references.insert(reference).inserted else {
                throw GenerationError.unsupportedSchema("Duplicate oneOf branch")
            }
            let object = try normalizedSchema(schemas[component]!, schemas: schemas, expanding: [component])
            guard object.type == "object", object.required?.contains(discriminator.propertyName) == true,
                let property = object.properties?[discriminator.propertyName],
                property.type == "string", property.format == nil, property.nullable != true
            else {
                throw GenerationError.unsupportedSchema(
                    "Discriminator must be a required nonnullable string on \(component)")
            }
            let mappedTags = (discriminator.mapping ?? [:]).filter { $0.value == reference }.map(\.key).sorted()
            let tags = mappedTags.isEmpty ? [component] : mappedTags
            for tag in tags {
                guard seenTags.insert(tag).inserted else {
                    throw GenerationError.unsupportedSchema("Ambiguous discriminator tag")
                }
                variants.append((tag, sanitize(component), safeIdentifier(discriminator.propertyName)))
            }
        }
        guard (discriminator.mapping ?? [:]).values.allSatisfy({ references.contains($0) }) else {
            throw GenerationError.unsupportedSchema("Discriminator mapping points outside oneOf")
        }
        var lines = [
            generatedHeader(comment: "Discriminated schema \(name)"), "import Foundation",
            "public enum \(name): Codable, Sendable, Equatable {",
        ]
        for (index, variant) in variants.enumerated() { lines.append("    case variant\(index)(\(variant.type))") }
        lines += [
            "    private enum DiscriminatorKey: String, CodingKey { case tag = \"\(swiftStringLiteralContent(discriminator.propertyName))\" }",
            "    public init(from decoder: any Decoder) throws {",
            "        let container = try decoder.container(keyedBy: DiscriminatorKey.self)",
            "        switch try container.decode(String.self, forKey: .tag) {",
        ]
        for (index, variant) in variants.enumerated() {
            lines.append(
                "        case \"\(swiftStringLiteralContent(variant.tag))\": self = .variant\(index)(try \(variant.type)(from: decoder))"
            )
        }
        lines += [
            "        default: throw DecodingError.dataCorruptedError(forKey: .tag, in: container, debugDescription: \"Unknown discriminator\")",
            "        }", "    }", "    public func encode(to encoder: any Encoder) throws {", "        switch self {",
        ]
        for (index, variant) in variants.enumerated() {
            lines += [
                "        case .variant\(index)(let value):",
                "            guard value.\(variant.property) == \"\(swiftStringLiteralContent(variant.tag))\" else { throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: \"Mismatched discriminator\")) }",
                "            try value.encode(to: encoder)",
            ]
        }
        lines += ["        }", "    }", "}"]
        return GeneratedFile(filename: "\(name).swift", contents: lines.joined(separator: "\n") + "\n")
    }
}
