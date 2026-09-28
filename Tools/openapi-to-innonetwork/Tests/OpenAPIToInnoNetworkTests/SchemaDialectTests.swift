import Foundation
import Testing

@testable import openapi_to_innonetwork

@Suite("OpenAPI 3.1 milestone admission")
struct SchemaDialectTests {
    func generate(_ json: String) throws -> [GeneratedFile] {
        try CodeGenerator(moduleName: "Modern").generate(
            from: decodeOpenAPIDocument(from: Data(json.utf8), sourceExtension: "json"))
    }

    @Test func modernTypesAndBooleanSchemas() throws {
        let files = try generate(
            #"{"openapi":"3.1.1","paths":{},"components":{"schemas":{"Accept":true,"Deny":false,"Maybe":{"type":["integer","null"]}}}}"#
        )
        #expect(files.count == 3)
        #expect(files.allSatisfy { $0.contents.contains("dialect: .jsonSchema202012") })
    }

    @Test(arguments: [
        #"{"openapi":"3.1.1","jsonSchemaDialect":"https://example.com/dialect","paths":{}}"#,
        #"{"openapi":"3.1.1","paths":{},"webhooks":{}}"#,
        #"{"openapi":"3.1.1","paths":{"/x":{"trace":{}}}}"#,
        #"{"openapi":"3.1.1","paths":{"/x":{"get":{"callbacks":{}}}}}"#,
        #"{"openapi":"3.1.1","paths":{"/x":{"post":{"requestBody":{"content":{"text/plain":{}}}}}}}"#,
        #"{"openapi":"3.0.3","paths":{},"components":{"schemas":{"Boolean":true}}}"#,
        #"{"openapi":"3.1.1","paths":{},"components":{"schemas":{"Legacy":{"type":"string","nullable":true}}}}"#,
        #"{"openapi":"3.2.0","paths":{}}"#,
    ])
    func rejectUnsupportedRolesAndDialectMixing(_ json: String) {
        #expect(throws: GenerationError.self) { try generate(json) }
    }

    @Test func constructedModelsCannotBypassNormalizationDepth() throws {
        var deep = Schema(type: "string")
        for _ in 0..<20 { deep = Schema(type: "array", items: Box(deep)) }
        #expect(throws: GenerationError.self) {
            try CodeGenerator(moduleName: "Depth").generate(
                from: OpenAPIDocument(paths: [:], components: Components(schemas: ["Deep": deep])))
        }
        let shallow = Schema(type: "array", items: Box(Schema(type: "string")))
        #expect(
            try CodeGenerator(moduleName: "Depth").generate(
                from: OpenAPIDocument(paths: [:], components: Components(schemas: ["Shallow": shallow]))
            ).count == 1)
    }
}
