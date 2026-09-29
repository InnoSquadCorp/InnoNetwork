import Foundation
import InnoNetwork
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
// The 6.0 preview adds declared scalar path parameters, explicit bearer
// security requirements, object allOf, discriminated oneOf and nullable
// properties. Unsupported contracts fail generation; this is not a complete
// OpenAPI implementation or a general JSON Schema validator.

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
    case unsupportedSecurity(String)
    case namingCollision(String)

    var description: String {
        switch self {
        case .invalidArgument(let arg): return "Invalid argument: \(arg)"
        case .missingArgument(let msg): return "Missing argument: \(msg)"
        case .ioFailure(let msg): return "I/O failure: \(msg)"
        case .parseFailure(let msg): return "Parse failure: \(msg)"
        case .unsupportedPath(let msg): return "Unsupported OpenAPI feature: \(msg)"
        case .unsupportedSchema(let msg): return "Unsupported OpenAPI feature: \(msg)"
        case .namingCollision(let msg): return "Generated name collision: \(msg)"
        case .unsupportedSecurity(let msg): return "Unsupported security: \(msg)"
        }
    }
}

// MARK: - OpenAPI subset model

struct OpenAPIDocument: Decodable, Equatable {
    var openapi: String?
    var jsonSchemaDialect: String?
    var paths: [String: PathItem]
    var components: Components?
    var security: [[String: [String]]]?

    init(
        paths: [String: PathItem], components: Components? = nil, security: [[String: [String]]]? = nil,
        openapi: String? = nil
    ) {
        self.openapi = openapi
        self.paths = paths
        self.components = components
        self.security = security
    }
}

struct Components: Decodable, Equatable {
    var schemas: [String: Schema]?
    var securitySchemes: [String: SecurityScheme]? = nil
}

struct SecurityScheme: Decodable, Equatable {
    var type: String
    var scheme: String?
    var name: String? = nil
    var `in`: String? = nil
    var flows: [String: OAuthFlow]? = nil
}

struct OAuthFlow: Decodable, Equatable {
    var authorizationUrl: String?
    var tokenUrl: String?
    var refreshUrl: String?
    var scopes: [String: String]
}

struct PathParameter: Decodable, Equatable {
    var name: String
    var `in`: String
    var required: Bool?
    var schema: Schema?
    var style: String?
    var explode: Bool?
}

struct PathItem: Decodable, Equatable {
    var get: Operation?
    var post: Operation?
    var put: Operation?
    var patch: Operation?
    var delete: Operation?
    var parameters: [PathParameter]?

    init(
        get: Operation? = nil,
        post: Operation? = nil,
        put: Operation? = nil,
        patch: Operation? = nil,
        delete: Operation? = nil,
        parameters: [PathParameter]? = nil
    ) {
        self.get = get
        self.post = post
        self.put = put
        self.patch = patch
        self.delete = delete
        self.parameters = parameters
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
    var parameters: [PathParameter]?
    var security: [[String: [String]]]?

    init(
        operationId: String? = nil,
        summary: String? = nil,
        requestBody: RequestBody? = nil,
        responses: [String: ResponseObject]? = nil,
        parameters: [PathParameter]? = nil,
        security: [[String: [String]]]? = nil
    ) {
        self.operationId = operationId
        self.summary = summary
        self.requestBody = requestBody
        self.responses = responses
        self.parameters = parameters
        self.security = security
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
/// Composition and nullable contracts are validated before rendering.
/// This serialization subset is not a general JSON Schema validator.
struct Schema: Decodable, Equatable {
    var preservedSchema: PreservedJSON?
    var booleanSchema: Bool?
    var typeAlternatives: [String]?
    var ref: String?
    var type: String?
    var properties: [String: Schema]?
    var required: [String]?
    var items: Box<Schema>?
    var format: String?
    var allOf: [Schema]?
    var oneOf: [Schema]?
    var anyOf: [Schema]?
    var nullable: Bool?
    var discriminator: Discriminator?
    var additionalProperties: Bool?
    var unsupportedValidationKeywords: Set<String> = []

    enum CodingKeys: String, CodingKey {
        case ref = "$ref"
        case type
        case properties
        case required
        case items
        case format
        case allOf, oneOf, anyOf, nullable, discriminator
        case additionalProperties
    }

    init(
        ref: String? = nil,
        type: String? = nil,
        properties: [String: Schema]? = nil,
        required: [String]? = nil,
        items: Box<Schema>? = nil,
        format: String? = nil,
        allOf: [Schema]? = nil,
        oneOf: [Schema]? = nil,
        anyOf: [Schema]? = nil,
        nullable: Bool? = nil,
        discriminator: Discriminator? = nil,
        additionalProperties: Bool? = nil,
        unsupportedValidationKeywords: Set<String> = []
    ) {
        self.ref = ref
        self.type = type
        self.properties = properties
        self.required = required
        self.items = items
        self.format = format
        self.allOf = allOf
        self.oneOf = oneOf
        self.anyOf = anyOf
        self.nullable = nullable
        self.discriminator = discriminator
        self.additionalProperties = additionalProperties
        self.unsupportedValidationKeywords = unsupportedValidationKeywords
    }

    init(from decoder: any Decoder) throws {
        // Bound the decoding stack before recursively constructing Schema/Box,
        // not only after the model reaches the graph compiler.
        guard decoder.codingPath.count < 32 else {
            throw GenerationError.unsupportedSchema("Schema input exceeds the 32-level decoding path limit")
        }
        self.preservedSchema = try? PreservedJSON(from: decoder)
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.booleanSchema = try decoder.singleValueContainer().decode(Bool.self)
            return
        }
        self.ref = try container.decodeIfPresent(String.self, forKey: .ref)
        if container.contains(.type), try !container.decodeNil(forKey: .type) {
            if let type = try? container.decode(String.self, forKey: .type) {
                self.type = type
            } else {
                self.typeAlternatives = try container.decode([String].self, forKey: .type)
            }
        }
        self.properties = try container.decodeIfPresent([String: Schema].self, forKey: .properties)
        self.required = try container.decodeIfPresent([String].self, forKey: .required)
        self.items = try container.decodeIfPresent(Box<Schema>.self, forKey: .items)
        self.format = try container.decodeIfPresent(String.self, forKey: .format)
        self.allOf = try container.decodeIfPresent([Schema].self, forKey: .allOf)
        self.oneOf = try container.decodeIfPresent([Schema].self, forKey: .oneOf)
        self.anyOf = try container.decodeIfPresent([Schema].self, forKey: .anyOf)
        self.nullable = try container.decodeIfPresent(Bool.self, forKey: .nullable)
        self.discriminator = try container.decodeIfPresent(Discriminator.self, forKey: .discriminator)
        self.additionalProperties = try? container.decode(Bool.self, forKey: .additionalProperties)
        let keys = try decoder.container(keyedBy: SchemaKeyword.self).allKeys.map(\.stringValue)
        let supported: Set<String> = [
            "$ref", "type", "properties", "required", "items", "format", "allOf", "oneOf",
            "anyOf", "nullable", "discriminator", "additionalProperties", "title", "description", "example",
            "deprecated", "externalDocs",
        ]
        self.unsupportedValidationKeywords = Set(keys).subtracting(supported)
        if container.contains(.additionalProperties), additionalProperties == nil {
            unsupportedValidationKeywords.insert("additionalProperties (non-boolean)")
        }
        for key in container.allKeys where try container.decodeNil(forKey: key) {
            unsupportedValidationKeywords.insert("\(key.rawValue) (null)")
        }
    }
}

private struct SchemaKeyword: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

struct Discriminator: Decodable, Equatable {
    var propertyName: String
    var mapping: [String: String]?
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

    // Generated declarations share a module with unqualified protocol,
    // witness, Foundation, and Swift types used in emitted source.
    private static let referencedTypeNames: Set<String> = [
        "APIDefinition", "Bool", "Codable", "Date", "Decodable", "DecodingError",
        "Decoder", "Double", "EmptyParameter", "EmptyResponse", "Encodable", "Encoder",
        "Equatable", "Float", "HTTPMethod", "Int", "Int64", "Sendable",
        "SessionAuthentication", "String", "URL", "EndpointPathEncoding", "EncodingError",
        "RequestSecurityProviding", "RequestSecurity", "RequestCredentialProvider",
        "PreservedJSON", "PreservedJSONCoding", "JSONSchema", "JSONProcessingLimits", "JSONProcessingError",
        "TransportPolicy", "JSONSchemaPlan", "JSONSchemaDialect", "Result", "Error",
    ]

    func generate(from document: OpenAPIDocument) throws -> [GeneratedFile] {
        let dialect = try schemaDialect(document)
        var files: [GeneratedFile] = []
        var generatedNames: [String: String] = [:]
        var needsAnyCodable = false
        if let schemas = document.components?.schemas {
            for (name, schema) in schemas.sorted(by: { $0.key < $1.key }) {
                try validateAliasChain(name: name, schemas: schemas)
                let preserved = try dialect == .jsonSchema202012 || needsCompiledSchema(schema, schemas: schemas)
                let schema = preserved ? schema : try normalizedSchema(schema, schemas: schemas, expanding: [name])
                let typeName = sanitize(name)
                try reserveGeneratedName(typeName, source: "schema '\(name)'", in: &generatedNames)
                if preserved {
                    files.append(
                        try renderCompiledSchema(name: typeName, schema: schema, schemas: schemas, dialect: dialect))
                } else if schema.anyOf != nil {
                    if let version = document.openapi, !version.hasPrefix("3.0.") {
                        throw GenerationError.unsupportedSchema("anyOf currently supports the OpenAPI 3.0 dialect only")
                    }
                    files.append(try renderAnyOf(name: typeName, schema: schema, schemas: schemas))
                } else if schema.oneOf != nil {
                    files.append(try renderUnion(name: typeName, schema: schema, schemas: schemas))
                } else {
                    files.append(try renderSchema(name: typeName, schema: schema))
                    needsAnyCodable = needsAnyCodable || schemaNeedsAnyCodable(schema)
                }
            }
        }
        if needsAnyCodable {
            try reserveGeneratedName("AnyCodable", source: "fallback model", in: &generatedNames)
            files.append(renderAnyCodable())
        }
        for (path, item) in document.paths.sorted(by: { $0.key < $1.key }) {
            for (method, op) in item.operationsByMethod {
                let operationSchemas =
                    [op.requestBody?.content?["application/json"]?.schema]
                    + (op.responses ?? [:]).values.map { $0.content?["application/json"]?.schema }
                for schema in operationSchemas.compactMap({ $0 }) {
                    if try dialect == .jsonSchema202012
                        || needsCompiledSchema(schema, schemas: document.components?.schemas ?? [:]), schema.ref == nil
                    {
                        throw GenerationError.unsupportedSchema(
                            "Constrained operation bodies require a named component reference")
                    }
                    if dialect == .openAPI30,
                        try !needsCompiledSchema(schema, schemas: document.components?.schemas ?? [:])
                    {
                        _ = try normalizedSchema(schema, schemas: document.components?.schemas ?? [:], expanding: [])
                    }
                    guard schema.nullable != true, swiftTypeName(for: schema, fallback: nil) != nil else {
                        throw GenerationError.unsupportedSchema(
                            "Operation bodies must use primitive/array types or a named component reference")
                    }
                }
                let typeName = sanitize(op.operationId ?? "\(method.lowercased())\(path)")
                try reserveGeneratedName(
                    typeName,
                    source: "\(method) \(path) (operationId '\(op.operationId ?? "<missing>")')",
                    in: &generatedNames
                )
                let security = try SecurityIR(
                    requirements: op.security ?? document.security,
                    schemes: document.components?.securitySchemes ?? [:]
                )
                let legacyAuthentication = try? security.legacySessionAuthentication()
                var preservesJSON = dialect == .jsonSchema202012
                for schema in operationSchemas.compactMap({ $0 }) {
                    if try containsAnyOf(schema, schemas: document.components?.schemas ?? [:])
                        || needsCompiledSchema(schema, schemas: document.components?.schemas ?? [:])
                    {
                        preservesJSON = true
                    }
                }
                files.append(
                    try renderOperation(
                        typeName: typeName, method: method, path: path, op: op,
                        pathParameters: item.parameters ?? [],
                        authentication: legacyAuthentication ?? "anonymous",
                        security: legacyAuthentication == nil ? security : nil, preservesJSON: preservesJSON))
            }
        }
        return files
    }

    func reserveGeneratedName(
        _ name: String,
        source: String,
        in names: inout [String: String]
    ) throws {
        // Swift types share a module namespace. Match case-insensitively as
        // well because generated files also have to coexist on the default
        // case-insensitive Apple file systems.
        let key = name.lowercased()
        if Self.referencedTypeNames.contains(where: { $0.lowercased() == key }) {
            throw GenerationError.namingCollision(
                "\(source) maps to '\(name)', which the generated client uses as a library or standard type. Rename the operationId or schema."
            )
        }
        if let existing = names[key] {
            throw GenerationError.namingCollision(
                "\(existing) and \(source) both map to '\(name).swift'. Rename an operationId or schema."
            )
        }
        names[key] = source
    }

    // MARK: Schema → Codable struct

    func renderSchema(name: String, schema: Schema) throws -> GeneratedFile {
        guard schema.nullable != true else {
            throw GenerationError.unsupportedSchema("Nullable component roots require a hand-written model: \(name)")
        }
        if let type = swiftTypeName(for: schema, fallback: nil) {
            return GeneratedFile(
                filename: "\(name).swift", contents: "import Foundation\npublic typealias \(name) = \(type)\n")
        }
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
                let optional = !required.contains(propName) || propSchema.nullable == true
                let swiftType = swiftTypeName(for: propSchema, fallback: "AnyCodable") ?? "AnyCodable"
                let typeAnnotation = optional ? "\(swiftType)?" : swiftType
                lines.append("    public var \(id): \(typeAnnotation)")
            }
            lines.append("")
            let initParams = sortedProps.map { prop -> String in
                let optional = !required.contains(prop.name) || prop.schema.nullable == true
                let swiftType = swiftTypeName(for: prop.schema, fallback: "AnyCodable") ?? "AnyCodable"
                let typeAnnotation = optional ? "\(swiftType)? = nil" : swiftType
                return "\(prop.id): \(typeAnnotation)"
            }
            lines.append("    public init(\(initParams.joined(separator: ", "))) {")
            for (_, id, _) in sortedProps {
                lines.append("        self.\(id) = \(id)")
            }
            lines.append("    }")
            let hasRequiredNullable = sortedProps.contains { required.contains($0.name) && $0.schema.nullable == true }
            if sortedProps.contains(where: { $0.id != $0.name }) || hasRequiredNullable {
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
            if hasRequiredNullable {
                lines.append("    public init(from decoder: any Decoder) throws {")
                lines.append("        let container = try decoder.container(keyedBy: CodingKeys.self)")
                for prop in sortedProps {
                    let type = swiftTypeName(for: prop.schema, fallback: "AnyCodable") ?? "AnyCodable"
                    let optional = !required.contains(prop.name) || prop.schema.nullable == true
                    if required.contains(prop.name), prop.schema.nullable == true {
                        lines.append(
                            "        guard container.contains(.\(prop.id)) else { throw DecodingError.keyNotFound(CodingKeys.\(prop.id), .init(codingPath: decoder.codingPath, debugDescription: \"Missing required nullable property\")) }"
                        )
                    }
                    lines.append(
                        "        self.\(prop.id) = try container.\(optional ? "decodeIfPresent" : "decode")(\(type).self, forKey: .\(prop.id))"
                    )
                }
                lines.append("    }")
                lines.append("    public func encode(to encoder: any Encoder) throws {")
                lines.append("        var container = encoder.container(keyedBy: CodingKeys.self)")
                for prop in sortedProps {
                    lines.append(
                        "        try container.\(required.contains(prop.name) ? "encode" : "encodeIfPresent")(self.\(prop.id), forKey: .\(prop.id))"
                    )
                }
                lines.append("    }")
            }
        } else {
            lines.append("    public init() {}")
        }
        lines.append("}")
        return GeneratedFile(filename: "\(name).swift", contents: lines.joined(separator: "\n") + "\n")
    }

    func schemaPropertyMappings(
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

    func renderAnyCodable() -> GeneratedFile {
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

    func renderOperation(
        typeName: String, method: String, path: String, op: Operation,
        pathParameters: [PathParameter], authentication: String, security: SecurityIR? = nil,
        preservesJSON: Bool = false
    ) throws -> GeneratedFile {
        // A template without declared parameters must never become a literal
        // endpoint. Fully declared scalar parameters are bound below.
        if let range = path.range(of: #"\{[^/{}]*\}"#, options: .regularExpression),
            pathParameters.isEmpty && (op.parameters ?? []).isEmpty
        {
            // `*` (not `+`) so `{}` is rejected too. An empty placeholder is
            // pointless but, before this, slipped past both this gate and
            // the forbidden-scalar set below — defeating the validator's
            // stated purpose of refusing any path template.
            let placeholder = String(path[range])
            throw GenerationError.unsupportedPath(
                "path template '\(placeholder)' in '\(path)' is not supported. "
                    + "Declare each placeholder as a required scalar path parameter. "
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

        let boundPath = try bindPath(path, inherited: pathParameters, operation: op.parameters ?? [])
        let parameter = op.requestBody?.content?["application/json"]?.schema
        let parameterType = parameter.flatMap { swiftTypeName(for: $0, fallback: nil) } ?? "EmptyParameter"
        if preservesJSON, parameterType != "EmptyParameter", ["GET", "HEAD", "TRACE"].contains(method.uppercased()) {
            throw GenerationError.unsupportedSchema(
                "Preserved JSON operation bodies require a body-capable HTTP method")
        }

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
            lines.append(contentsOf: commentLines(summary, prefix: "/// "))
        } else {
            lines.append("/// Generated by openapi-to-innonetwork.")
        }
        if let responseSource {
            lines.append("/// Response source: \(responseSource).")
        }
        let securityLiteral = try security?.runtimeAlternativesLiteral()
        let conformance = security == nil ? "APIDefinition" : "APIDefinition, RequestSecurityProviding"
        lines.append("public struct \(typeName): \(conformance) {")
        lines.append("    public typealias Parameter = \(parameterType)")
        lines.append("    public typealias APIResponse = \(responseType)")
        lines.append("")
        if security != nil { lines.append("    public let requestSecurity: RequestSecurity") }
        if parameterType != "EmptyParameter" {
            lines.append("    public let parameters: \(parameterType)?")
        }
        for argument in boundPath.arguments {
            lines.append("    public let \(argument.name): \(argument.type)")
        }
        lines.append("    public var method: HTTPMethod { .\(method.lowercased()) }")
        lines.append("    public var path: String { \"\(boundPath.literal)\" }")
        // Emit the validated security contract explicitly.
        lines.append("    public var sessionAuthentication: SessionAuthentication { .\(authentication) }")
        if preservesJSON {
            let encoding = parameterType == "EmptyParameter" ? ".none" : ".preservedJSON(limits: .init())"
            lines += [
                "    public var transport: TransportPolicy<APIResponse> {",
                "        .custom(encoding: \(encoding)) { data, response in",
            ]
            if responseType == "EmptyResponse" {
                lines.append("            if data.isEmpty || response.statusCode == 204 { return EmptyResponse() }")
            }
            lines += [
                "            return try PreservedJSONCoding.decode(APIResponse.self, from: data)",
                "        }", "    }",
            ]
        }
        lines.append("")
        var initParameters = boundPath.arguments.map { "\($0.name): \($0.type)" }
        if security != nil {
            initParameters += [
                "credentialOrigin: URL", "credentialProvider: any RequestCredentialProvider",
                "allowsQueryCredentials: Bool = false", "allowsCookieCredentials: Bool = false",
            ]
        }
        if parameterType != "EmptyParameter" { initParameters.append("parameters: \(parameterType)? = nil") }
        if !initParameters.isEmpty {
            let throwing = security == nil ? "" : " throws"
            lines.append("    public init(\(initParameters.joined(separator: ", ")))\(throwing) {")
            if let securityLiteral {
                lines.append("        self.requestSecurity = try RequestSecurity(")
                lines.append(
                    "            origin: credentialOrigin, alternatives: \(securityLiteral), provider: credentialProvider,"
                )
                lines.append(
                    "            allowsQueryCredentials: allowsQueryCredentials, allowsCookieCredentials: allowsCookieCredentials)"
                )
            }
            for argument in boundPath.arguments { lines.append("        self.\(argument.name) = \(argument.name)") }
            if parameterType != "EmptyParameter" { lines.append("        self.parameters = parameters") }
            lines.append("    }")
        } else {
            lines.append("    public init() {}")
        }
        lines.append("}")
        return GeneratedFile(filename: "\(typeName).swift", contents: lines.joined(separator: "\n") + "\n")
    }

    // MARK: Helpers

    func generatedHeader(comment: String) -> String {
        (["// Generated by openapi-to-innonetwork. DO NOT EDIT BY HAND."]
            + commentLines("Module: \(moduleName)", prefix: "// ")
            + commentLines(comment, prefix: "// "))
            .joined(separator: "\n")
    }

    func commentLines(_ raw: String, prefix: String) -> [String] {
        var normalized = ""
        var precedingWasCarriageReturn = false
        for scalar in raw.unicodeScalars {
            if scalar.value == 0x0A && precedingWasCarriageReturn {
                precedingWasCarriageReturn = false
                continue
            }
            precedingWasCarriageReturn = scalar.value == 0x0D
            switch scalar.value {
            case 0x0A, 0x0D, 0x2028, 0x2029:
                normalized.append("\n")
            case 0x00...0x1F, 0x7F:
                normalized.append(" ")
            default:
                normalized.unicodeScalars.append(scalar)
            }
        }
        return normalized.components(separatedBy: "\n").map { prefix + $0 }
    }

    func swiftTypeName(for schema: Schema, fallback: String?) -> String? {
        if let ref = schema.ref {
            guard let name = try? referenceToken(ref) else { return nil }
            return sanitize(name)
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

    func schemaNeedsAnyCodable(_ schema: Schema) -> Bool {
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

    func sanitize(_ raw: String) -> String {
        var result = ""
        var capitalizeNext = true
        for scalar in raw.unicodeScalars {
            if (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
                || (48...57).contains(scalar.value)
            {
                let char = String(scalar)
                result += capitalizeNext ? char.uppercased() : char
                capitalizeNext = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                // Keep Unicode source names distinct while emitting an ASCII
                // Swift identifier that compiles on every supported toolchain.
                result += "U\(String(scalar.value, radix: 16, uppercase: true))"
                capitalizeNext = false
            } else {
                capitalizeNext = true
            }
        }
        if result.isEmpty { result = "Generated" }
        if let first = result.first, first.isNumber { result = "_" + result }
        if Self.swiftReservedIdentifiers.contains(result) { result += "_" }
        return result
    }

    func safeIdentifier(_ raw: String) -> String {
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

    func swiftStringLiteralContent(_ raw: String) -> String {
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
            return try decodeJSONDocument(losslessYAMLJSON(text))
        } catch {
            throw GenerationError.parseFailure("YAML decode failed: \(error)")
        }
    } else {
        do {
            return try decodeJSONDocument(data)
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
    // Validate the complete generated namespace before creating or changing
    // output. A collision must not leave a partially updated client behind.
    let files = try CodeGenerator(moduleName: options.moduleName).generate(from: document)

    let outputDirectory = URL(fileURLWithPath: options.outputDirectory)
    do {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
    } catch {
        throw GenerationError.ioFailure("cannot create \(options.outputDirectory): \(error.localizedDescription)")
    }

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
