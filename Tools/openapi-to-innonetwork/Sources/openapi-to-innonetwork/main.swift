import Foundation
import Yams

// CLI: openapi-to-innonetwork --input <spec.{json,yaml,yml}> --output <dir>
//      [--module-name MyAPI]
//
// 5.0 expansion of the 4.x preview generator. Now reads YAML and JSON
// (input format inferred from the file extension), parses the
// `components.schemas` and per-operation `requestBody` / `responses`
// blocks, and emits:
//   - one Swift file per schema with a Codable struct that mirrors the
//     OpenAPI properties.
//   - one Swift file per operation with an APIDefinition-conforming
//     struct whose Parameter / APIResponse associated types are wired
//     to the generated schema types when the spec uses $ref.
// The input subset still focuses on object schemas with primitive +
// array + nested-$ref properties; full OpenAPI feature coverage
// (oneOf / allOf / discriminators / nullable / parameter location
// fan-out) is a future expansion.

struct CLIOptions {
    var inputPath: String
    var outputDirectory: String
    var moduleName: String

    static func parse(_ args: [String]) throws -> CLIOptions {
        var input: String?
        var output: String?
        var moduleName = "GeneratedAPI"
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--input", "-i":
                index += 1
                input = index < args.count ? args[index] : nil
            case "--output", "-o":
                index += 1
                output = index < args.count ? args[index] : nil
            case "--module-name":
                index += 1
                if index < args.count { moduleName = args[index] }
            case "--help", "-h":
                print(usage)
                exit(0)
            default:
                throw GenerationError.invalidArgument(args[index])
            }
            index += 1
        }
        guard let input, let output else {
            throw GenerationError.missingArgument("--input and --output are required. Run with --help for usage.")
        }
        return CLIOptions(inputPath: input, outputDirectory: output, moduleName: moduleName)
    }

    static let usage = """
        openapi-to-innonetwork — InnoNetwork APIDefinition generator

        USAGE:
            swift run openapi-to-innonetwork --input <spec.{json,yaml,yml}> --output <dir> [--module-name MyAPI]

        FLAGS:
            -i, --input         Path to a JSON or YAML OpenAPI 3 document.
                                Format inferred from the file extension.
            -o, --output        Output directory for generated Swift files.
                --module-name   Module name embedded in the generated files
                                (default: GeneratedAPI).
            -h, --help          Show this help.

        OUTPUT:
            • One Swift file per schema in components.schemas (Codable struct).
            • One Swift file per OpenAPI operation (APIDefinition struct).
            • Generated structs reference the schema types when the spec
              uses $ref in requestBody / responses.
        """
}

enum GenerationError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case missingArgument(String)
    case ioFailure(String)
    case parseFailure(String)
    case unsupportedPath(String)
    case unsupportedSchema(String)

    var description: String {
        switch self {
        case .invalidArgument(let arg): return "Invalid argument: \(arg)"
        case .missingArgument(let msg): return "Missing argument: \(msg)"
        case .ioFailure(let msg): return "I/O failure: \(msg)"
        case .parseFailure(let msg): return "Parse failure: \(msg)"
        case .unsupportedPath(let msg): return "Unsupported OpenAPI feature: \(msg)"
        case .unsupportedSchema(let msg): return "Unsupported OpenAPI feature: \(msg)"
        }
    }
}

// MARK: - OpenAPI subset model

struct OpenAPIDocument: Decodable, Equatable {
    var paths: [String: PathItem]
    var components: Components?

    init(paths: [String: PathItem], components: Components? = nil) {
        self.paths = paths
        self.components = components
    }
}

struct Components: Decodable, Equatable {
    var schemas: [String: Schema]?
}

struct PathItem: Decodable, Equatable {
    var get: Operation?
    var post: Operation?
    var put: Operation?
    var patch: Operation?
    var delete: Operation?

    init(
        get: Operation? = nil,
        post: Operation? = nil,
        put: Operation? = nil,
        patch: Operation? = nil,
        delete: Operation? = nil
    ) {
        self.get = get
        self.post = post
        self.put = put
        self.patch = patch
        self.delete = delete
    }

    var operationsByMethod: [(method: String, op: Operation)] {
        var out: [(String, Operation)] = []
        if let get { out.append(("GET", get)) }
        if let post { out.append(("POST", post)) }
        if let put { out.append(("PUT", put)) }
        if let patch { out.append(("PATCH", patch)) }
        if let delete { out.append(("DELETE", delete)) }
        return out
    }
}

struct Operation: Decodable, Equatable {
    var operationId: String?
    var summary: String?
    var requestBody: RequestBody?
    var responses: [String: ResponseObject]?

    init(
        operationId: String? = nil,
        summary: String? = nil,
        requestBody: RequestBody? = nil,
        responses: [String: ResponseObject]? = nil
    ) {
        self.operationId = operationId
        self.summary = summary
        self.requestBody = requestBody
        self.responses = responses
    }
}

struct RequestBody: Decodable, Equatable {
    var content: [String: MediaType]?
}

struct ResponseObject: Decodable, Equatable {
    var description: String?
    var content: [String: MediaType]?
}

struct MediaType: Decodable, Equatable {
    var schema: Schema?
}

/// Schema subset: object with properties, primitives, arrays, $ref.
/// Other variants (oneOf / allOf / discriminator / nullable) decode as
/// `.unsupported` so the generator can skip them while still producing
/// usable scaffolding for the parts of the spec it understands.
struct Schema: Decodable, Equatable {
    var ref: String?
    var type: String?
    var properties: [String: Schema]?
    var required: [String]?
    var items: Box<Schema>?
    var format: String?

    enum CodingKeys: String, CodingKey {
        case ref = "$ref"
        case type
        case properties
        case required
        case items
        case format
    }

    init(
        ref: String? = nil,
        type: String? = nil,
        properties: [String: Schema]? = nil,
        required: [String]? = nil,
        items: Box<Schema>? = nil,
        format: String? = nil
    ) {
        self.ref = ref
        self.type = type
        self.properties = properties
        self.required = required
        self.items = items
        self.format = format
    }
}

/// Heap-indirection wrapper so `Schema` can recursively contain itself
/// through `items`. Plain stored properties of the same value type
/// would create an infinite-size struct.
final class Box<T: Decodable & Equatable>: Decodable, Equatable {
    let value: T

    init(_ value: T) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try container.decode(T.self)
    }

    static func == (lhs: Box<T>, rhs: Box<T>) -> Bool {
        lhs.value == rhs.value
    }
}

// MARK: - Codegen

struct GeneratedFile {
    let filename: String
    let contents: String
}

struct CodeGenerator {
    let moduleName: String

    private static let swiftReservedIdentifiers: Set<String> = [
        "Any", "Protocol", "Self", "Type", "actor", "as", "associatedtype",
        "associativity", "async", "await", "break", "case", "catch", "class",
        "continue", "convenience", "default", "defer", "deinit", "didSet",
        "do", "dynamic", "each", "else", "enum", "extension", "fallthrough",
        "false", "fileprivate", "final", "for", "func", "get", "guard", "if",
        "import", "in", "indirect", "infix", "init", "inout", "internal", "is",
        "isolated", "lazy", "left", "let", "macro", "mutating", "nil", "none",
        "nonisolated", "nonmutating", "open", "operator", "optional", "override",
        "package", "postfix", "precedence", "precedencegroup", "prefix", "private",
        "protocol", "public", "repeat", "required", "rethrows", "return", "right",
        "self", "set", "some", "static", "struct", "subscript", "super", "switch",
        "throw", "throws", "true", "try", "typealias", "unowned", "var", "weak",
        "where", "while", "willSet",
    ]

    func generate(from document: OpenAPIDocument) throws -> [GeneratedFile] {
        var files: [GeneratedFile] = []
        var needsAnyCodable = false
        if let schemas = document.components?.schemas {
            for (name, schema) in schemas.sorted(by: { $0.key < $1.key }) {
                files.append(try renderSchema(name: sanitize(name), schema: schema))
                needsAnyCodable = needsAnyCodable || schemaNeedsAnyCodable(schema)
            }
        }
        if needsAnyCodable {
            files.append(renderAnyCodable())
        }
        for (path, item) in document.paths.sorted(by: { $0.key < $1.key }) {
            for (method, op) in item.operationsByMethod {
                let typeName = sanitize(op.operationId ?? "\(method.lowercased())\(path)")
                files.append(try renderOperation(typeName: typeName, method: method, path: path, op: op))
            }
        }
        return files
    }

    // MARK: Schema → Codable struct

    private func renderSchema(name: String, schema: Schema) throws -> GeneratedFile {
        var lines: [String] = []
        lines.append(generatedHeader(comment: "Schema for \(name)"))
        lines.append("")
        lines.append("import Foundation")
        lines.append("")
        lines.append("public struct \(name): Codable, Sendable, Equatable {")
        if let properties = schema.properties, !properties.isEmpty {
            let required = Set(schema.required ?? [])
            let sortedProps = try schemaPropertyMappings(schemaName: name, properties: properties)
            for (propName, id, propSchema) in sortedProps {
                let optional = !required.contains(propName)
                let swiftType = swiftTypeName(for: propSchema, fallback: "AnyCodable") ?? "AnyCodable"
                let typeAnnotation = optional ? "\(swiftType)?" : swiftType
                lines.append("    public var \(id): \(typeAnnotation)")
            }
            lines.append("")
            let initParams = sortedProps.map { prop -> String in
                let optional = !required.contains(prop.name)
                let swiftType = swiftTypeName(for: prop.schema, fallback: "AnyCodable") ?? "AnyCodable"
                let typeAnnotation = optional ? "\(swiftType)? = nil" : swiftType
                return "\(prop.id): \(typeAnnotation)"
            }
            lines.append("    public init(\(initParams.joined(separator: ", "))) {")
            for (_, id, _) in sortedProps {
                lines.append("        self.\(id) = \(id)")
            }
            lines.append("    }")
            if sortedProps.contains(where: { $0.id != $0.name }) {
                lines.append("")
                lines.append("    private enum CodingKeys: String, CodingKey {")
                for (propName, id, _) in sortedProps {
                    if id == propName {
                        lines.append("        case \(id)")
                    } else {
                        lines.append("        case \(id) = \"\(swiftStringLiteralContent(propName))\"")
                    }
                }
                lines.append("    }")
            }
        } else {
            lines.append("    public init() {}")
        }
        lines.append("}")
        return GeneratedFile(filename: "\(name).swift", contents: lines.joined(separator: "\n") + "\n")
    }

    private func schemaPropertyMappings(
        schemaName: String,
        properties: [String: Schema]
    ) throws -> [(name: String, id: String, schema: Schema)] {
        var seenIdentifiers: [String: String] = [:]
        var mappings: [(name: String, id: String, schema: Schema)] = []
        for (propName, propSchema) in properties.sorted(by: { $0.key < $1.key }) {
            let id = safeIdentifier(propName)
            if let existingName = seenIdentifiers[id] {
                throw GenerationError.unsupportedSchema(
                    "schema '\(schemaName)' has properties '\(existingName)' and '\(propName)' "
                        + "that both map to Swift identifier '\(id)'. Rename one property or "
                        + "provide a hand-written model for this schema."
                )
            }
            seenIdentifiers[id] = propName
            mappings.append((name: propName, id: id, schema: propSchema))
        }
        return mappings
    }

    private func renderAnyCodable() -> GeneratedFile {
        let contents = """
            \(generatedHeader(comment: "Fallback type for unsupported schema properties"))

            import Foundation

            public indirect enum AnyCodable: Codable, Sendable, Equatable {
                case array([AnyCodable])
                case bool(Bool)
                case double(Double)
                case int(Int64)
                case null
                case object([String: AnyCodable])
                case string(String)

                public init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if container.decodeNil() {
                        self = .null
                    } else if let value = try? container.decode(Bool.self) {
                        self = .bool(value)
                    } else if let value = try? container.decode(Int64.self) {
                        self = .int(value)
                    } else if let value = try? container.decode(Double.self) {
                        self = .double(value)
                    } else if let value = try? container.decode(String.self) {
                        self = .string(value)
                    } else if let value = try? container.decode([AnyCodable].self) {
                        self = .array(value)
                    } else if let value = try? container.decode([String: AnyCodable].self) {
                        self = .object(value)
                    } else {
                        throw DecodingError.dataCorruptedError(
                            in: container,
                            debugDescription: "Unsupported JSON value for AnyCodable."
                        )
                    }
                }

                public func encode(to encoder: Encoder) throws {
                    var container = encoder.singleValueContainer()
                    switch self {
                    case .array(let value):
                        try container.encode(value)
                    case .bool(let value):
                        try container.encode(value)
                    case .double(let value):
                        try container.encode(value)
                    case .int(let value):
                        try container.encode(value)
                    case .null:
                        try container.encodeNil()
                    case .object(let value):
                        try container.encode(value)
                    case .string(let value):
                        try container.encode(value)
                    }
                }
            }
            """

        return GeneratedFile(filename: "AnyCodable.swift", contents: contents + "\n")
    }

    // MARK: Operation → APIDefinition struct

    private func renderOperation(typeName: String, method: String, path: String, op: Operation) throws -> GeneratedFile
    {
        // Reject `{name}` style path templates so they cannot be silently
        // emitted as a literal Swift string — a request hitting the
        // generated endpoint would post to `/users/{id}` verbatim and the
        // server would return 404 or a parameter-not-bound error. The
        // generator does not yet support path parameter substitution; the
        // user must rewrite the path or post-process the generated code.
        if let range = path.range(of: #"\{[^/{}]*\}"#, options: .regularExpression) {
            // `*` (not `+`) so `{}` is rejected too. An empty placeholder is
            // pointless but, before this, slipped past both this gate and
            // the forbidden-scalar set below — defeating the validator's
            // stated purpose of refusing any path template.
            let placeholder = String(path[range])
            throw GenerationError.unsupportedPath(
                "path template '\(placeholder)' in '\(path)' is not supported. "
                    + "Remove path parameters from the OpenAPI spec or generate a stripped variant; "
                    + "the openapi-to-innonetwork subset does not bind {name} placeholders. "
                    + "See Tools/openapi-to-innonetwork/README.md for the supported subset."
            )
        }

        // Reject paths containing characters that would either escape the
        // generated Swift string literal (`"`, `\`) or imply structured
        // substitution we don't support (newlines, NUL). RFC 3986 §3.3
        // forbids these in real URI paths anyway, but the generator reads
        // untrusted JSON/YAML so refuse them here instead of producing
        // invalid Swift source.
        let forbiddenScalars: Set<Unicode.Scalar> = [
            Unicode.Scalar(0x22)!,  // "
            Unicode.Scalar(0x5C)!,  // \
            Unicode.Scalar(0x0A)!,  // \n
            Unicode.Scalar(0x0D)!,  // \r
            Unicode.Scalar(0x00)!,  // \0
        ]
        if let bad = path.unicodeScalars.first(where: { forbiddenScalars.contains($0) }) {
            throw GenerationError.unsupportedPath(
                "path '\(path)' contains the unsupported character U+\(String(bad.value, radix: 16, uppercase: true)); "
                    + "remove it from the OpenAPI spec before regenerating."
            )
        }

        let parameter = op.requestBody?.content?["application/json"]?.schema
        let parameterType = parameter.flatMap { swiftTypeName(for: $0, fallback: nil) } ?? "EmptyParameter"

        // 200/201 carry a body and map to their JSON schema. 202 (Accepted)
        // and 204 (No Content) — RFC 9110 §15.3.3 / §15.3.5 — expressly do
        // not, so when only those are declared the operation maps to
        // `EmptyResponse` without falling through the generic "no schema
        // found" branch. This keeps async-job / DELETE / PATCH-without-echo
        // endpoints typed deliberately rather than by accident.
        let responseType: String
        let responseSource: String?
        if let schema =
            op.responses?["200"]?.content?["application/json"]?.schema
            ?? op.responses?["201"]?.content?["application/json"]?.schema,
            let typed = swiftTypeName(for: schema, fallback: nil)
        {
            responseType = typed
            responseSource = nil
        } else if op.responses?["202"] != nil {
            responseType = "EmptyResponse"
            responseSource = "202 Accepted"
        } else if op.responses?["204"] != nil {
            responseType = "EmptyResponse"
            responseSource = "204 No Content"
        } else {
            responseType = "EmptyResponse"
            responseSource = nil
        }

        var lines: [String] = []
        lines.append(generatedHeader(comment: "Operation: \(method) \(path)"))
        lines.append("")
        lines.append("import Foundation")
        lines.append("import InnoNetwork")
        lines.append("")
        if let summary = op.summary {
            lines.append("/// \(summary)")
        } else {
            lines.append("/// Generated by openapi-to-innonetwork.")
        }
        if let responseSource {
            lines.append("/// Response source: \(responseSource).")
        }
        lines.append("public struct \(typeName): APIDefinition {")
        lines.append("    public typealias Parameter = \(parameterType)")
        lines.append("    public typealias APIResponse = \(responseType)")
        lines.append("")
        if parameterType != "EmptyParameter" {
            lines.append("    public let parameters: \(parameterType)?")
        }
        lines.append("    public var method: HTTPMethod { .\(method.lowercased()) }")
        lines.append("    public var path: String { \"\(path)\" }")
        // The preview subset does not interpret OpenAPI security schemes.
        // Emit the protocol witness explicitly instead of relying on a
        // library default that could drift across generated clients.
        lines.append("    public var sessionAuthentication: SessionAuthentication { .anonymous }")
        lines.append("")
        if parameterType != "EmptyParameter" {
            lines.append("    public init(parameters: \(parameterType)? = nil) {")
            lines.append("        self.parameters = parameters")
            lines.append("    }")
        } else {
            lines.append("    public init() {}")
        }
        lines.append("}")
        return GeneratedFile(filename: "\(typeName).swift", contents: lines.joined(separator: "\n") + "\n")
    }

    // MARK: Helpers

    private func generatedHeader(comment: String) -> String {
        """
        // Generated by openapi-to-innonetwork. DO NOT EDIT BY HAND.
        // Module: \(moduleName)
        // \(comment)
        """
    }

    private func swiftTypeName(for schema: Schema, fallback: String?) -> String? {
        if let ref = schema.ref {
            return sanitize(ref.split(separator: "/").last.map(String.init) ?? "")
        }
        switch schema.type {
        case "string":
            switch schema.format {
            case "date-time", "date":
                return "Date"
            case "uri", "url":
                return "URL"
            default:
                return "String"
            }
        case "integer":
            return schema.format == "int64" ? "Int64" : "Int"
        case "number":
            return schema.format == "float" ? "Float" : "Double"
        case "boolean":
            return "Bool"
        case "array":
            if let inner = schema.items?.value, let elementType = swiftTypeName(for: inner, fallback: fallback) {
                return "[\(elementType)]"
            }
            return fallback
        default:
            return fallback
        }
    }

    private func schemaNeedsAnyCodable(_ schema: Schema) -> Bool {
        if schema.ref != nil {
            return false
        }
        if let properties = schema.properties {
            return properties.values.contains(where: schemaNeedsAnyCodable)
        }
        switch schema.type {
        case "string", "integer", "number", "boolean":
            return false
        case "array":
            guard let item = schema.items?.value else { return true }
            return schemaNeedsAnyCodable(item)
        default:
            return true
        }
    }

    private func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var result = ""
        var capitalizeNext = true
        for scalar in raw.unicodeScalars {
            if allowed.contains(scalar) {
                let char = String(scalar)
                result += capitalizeNext ? char.uppercased() : char
                capitalizeNext = false
            } else {
                capitalizeNext = true
            }
        }
        return result.isEmpty ? "Generated" : result
    }

    private func safeIdentifier(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "_"))
        var result = ""
        var capitalizeNext = false
        for scalar in raw.unicodeScalars {
            if allowed.contains(scalar) {
                let char = String(scalar)
                result += capitalizeNext ? char.uppercased() : char
                capitalizeNext = false
            } else {
                capitalizeNext = true
            }
        }
        if let first = result.first, first.isNumber {
            result = "_" + result
        }
        if result.isEmpty {
            result = "field"
        }
        if Self.swiftReservedIdentifiers.contains(result) {
            result += "_"
        }
        return result
    }

    private func swiftStringLiteralContent(_ raw: String) -> String {
        var result = ""
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x22:
                result += "\\\""
            case 0x5C:
                result += "\\\\"
            case 0x0A:
                result += "\\n"
            case 0x0D:
                result += "\\r"
            case 0x09:
                result += "\\t"
            case 0x00...0x1F:
                result += "\\u{\(String(scalar.value, radix: 16))}"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

// MARK: - Decoding

func decodeOpenAPIDocument(from data: Data, sourceExtension: String) throws -> OpenAPIDocument {
    let lowered = sourceExtension.lowercased()
    if lowered == "yaml" || lowered == "yml" {
        guard let text = String(data: data, encoding: .utf8) else {
            throw GenerationError.parseFailure("YAML input is not valid UTF-8.")
        }
        do {
            return try YAMLDecoder().decode(OpenAPIDocument.self, from: text)
        } catch {
            throw GenerationError.parseFailure("YAML decode failed: \(error)")
        }
    } else {
        do {
            return try JSONDecoder().decode(OpenAPIDocument.self, from: data)
        } catch {
            throw GenerationError.parseFailure("JSON decode failed: \(error)")
        }
    }
}

// MARK: - Entry point

func run() throws {
    let options = try CLIOptions.parse(CommandLine.arguments)

    let inputURL = URL(fileURLWithPath: options.inputPath)
    let data: Data
    do {
        data = try Data(contentsOf: inputURL)
    } catch {
        throw GenerationError.ioFailure("cannot read \(options.inputPath): \(error.localizedDescription)")
    }

    let document = try decodeOpenAPIDocument(from: data, sourceExtension: inputURL.pathExtension)

    let outputDirectory = URL(fileURLWithPath: options.outputDirectory)
    do {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
    } catch {
        throw GenerationError.ioFailure("cannot create \(options.outputDirectory): \(error.localizedDescription)")
    }

    let generator = CodeGenerator(moduleName: options.moduleName)
    let files = try generator.generate(from: document)
    for file in files {
        let fileURL = outputDirectory.appendingPathComponent(file.filename)
        do {
            try file.contents.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw GenerationError.ioFailure("cannot write \(fileURL.path): \(error.localizedDescription)")
        }
    }

    FileHandle.standardError.write(
        Data("openapi-to-innonetwork: wrote \(files.count) file(s) to \(outputDirectory.path)\n".utf8)
    )
}

do {
    try run()
} catch {
    FileHandle.standardError.write(
        Data("openapi-to-innonetwork: \(error)\n".utf8)
    )
    exit(1)
}
