import Foundation
import InnoNetwork

extension CodeGenerator {
    func schemaDialect(_ document: OpenAPIDocument) throws -> JSONSchemaDialect {
        guard let version = document.openapi else {
            guard document.jsonSchemaDialect == nil else {
                throw GenerationError.unsupportedSchema("Dialect requires OpenAPI 3.1")
            }
            return .openAPI30
        }
        let fields = version.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == "3", ["0", "1"].contains(fields[1]),
            !fields[2].isEmpty, fields[2].utf8.allSatisfy({ (48...57).contains($0) })
        else {
            throw GenerationError.unsupportedSchema("Only the documented OpenAPI 3.0/3.1 subsets are supported")
        }
        if fields[1] == "0" {
            guard document.jsonSchemaDialect == nil else {
                throw GenerationError.unsupportedSchema("Dialect requires OpenAPI 3.1")
            }
            return .openAPI30
        }
        guard
            document.jsonSchemaDialect == nil
                || ["https://json-schema.org/draft/2020-12/schema", "https://spec.openapis.org/oas/3.1/dialect/base"]
                    .contains(document.jsonSchemaDialect!)
        else {
            throw GenerationError.unsupportedSchema("Unsupported jsonSchemaDialect")
        }
        return .jsonSchema202012
    }
}

func decodeJSONDocument(_ data: Data) throws -> OpenAPIDocument {
    let document = try PreservedJSONCoding.decode(OpenAPIDocument.self, from: data)
    if try CodeGenerator(moduleName: "Validation").schemaDialect(document) == .jsonSchema202012 {
        try validateOpenAPI31Roles(data)
    }
    return document
}

/// Audits OpenAPI object roles, not schema/data property names.
private func validateOpenAPI31Roles(_ data: Data) throws {
    func object(_ value: PreservedJSON) throws -> [String: PreservedJSON] {
        try PreservedJSONCoding.decode([String: PreservedJSON].self, from: value.data)
    }
    func allowed(_ values: [String: PreservedJSON], _ names: Set<String>) throws {
        guard values.keys.allSatisfy({ names.contains($0) || $0.hasPrefix("x-") }) else {
            throw GenerationError.unsupportedSchema("Unsupported OpenAPI 3.1 generator role; see support matrix")
        }
    }
    func content(_ owner: PreservedJSON, response: Bool) throws {
        let values = try object(owner)
        try allowed(values, response ? ["description", "content"] : ["description", "required", "content"])
        if let content = values["content"] {
            let media = try object(content)
            guard media.keys.allSatisfy({ $0 == "application/json" }) else {
                throw GenerationError.unsupportedSchema("The 3.1 milestone supports application/json only")
            }
            for value in media.values { try allowed(object(value), ["schema", "example", "examples"]) }
        }
    }
    let root = try object(PreservedJSON(data: data))
    try allowed(
        root,
        ["openapi", "info", "servers", "paths", "components", "security", "tags", "externalDocs", "jsonSchemaDialect"])
    if let components = root["components"] { try allowed(object(components), ["schemas", "securitySchemes"]) }
    let methods: Set<String> = ["get", "post", "put", "patch", "delete"]
    let paths = try root["paths"].map(object) ?? [:]
    for item in paths.values {
        let members = try object(item)
        try allowed(members, methods.union(["summary", "description", "servers", "parameters"]))
        for (method, value) in members where methods.contains(method) {
            let operation = try object(value)
            try allowed(
                operation,
                [
                    "operationId", "summary", "description", "tags", "deprecated", "externalDocs", "servers",
                    "parameters", "requestBody", "responses", "security",
                ])
            if let body = operation["requestBody"] { try content(body, response: false) }
            if let responses = operation["responses"] {
                for response in try object(responses).values { try content(response, response: true) }
            }
        }
    }
}
