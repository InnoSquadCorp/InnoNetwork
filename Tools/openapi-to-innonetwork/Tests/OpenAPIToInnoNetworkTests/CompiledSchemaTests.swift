import Foundation
import Testing

@testable import openapi_to_innonetwork

@Suite("Lossless compiled schema generation")
struct CompiledSchemaTests {
    private static let nestedSchemas = [
        (#"{"type":"object","properties":{"value":CHILD}}"#, true),
        (#"{"anyOf":[{"type":"string"},CHILD]}"#, true),
        (#"{"allOf":[{"type":"object","properties":{"value":CHILD}}]}"#, false),
        (#"{"oneOf":[{"type":"string"},CHILD]}"#, false),
        (#"{"type":"array","items":CHILD}"#, true),
    ]

    private func generateSchema(_ schema: String) throws -> String {
        let json = #"{"openapi":"3.0.3","paths":{},"components":{"schemas":{"Value":"# + schema + "}}}"
        let document = try decodeOpenAPIDocument(from: Data(json.utf8), sourceExtension: "json")
        let files = try CodeGenerator(moduleName: "Test").generate(from: document)
        return try #require(files.first { $0.filename == "Value.swift" }?.contents)
    }

    @Test("Constraints in every child role select compiled validation", arguments: nestedSchemas)
    func nestedConstraints(_ schema: String, _ supported: Bool) throws {
        let child = #"{"type":"integer","minimum":7}"#
        let input = schema.replacingOccurrences(of: "CHILD", with: child)
        // allOf/oneOf assertions are outside the compiled subset. They must
        // reach its fail-closed validation, not silently become typed models.
        if !supported {
            let error = #expect(throws: GenerationError.self) {
                try generateSchema(input)
            }
            #expect(
                error?.description
                    == "Unsupported OpenAPI feature: Compiled schema validation failed: unsupportedSchema")
            return
        }
        let contents = try generateSchema(input)
        #expect(contents.contains("JSONSchemaPlan"))
        #expect(contents.contains("public let json: PreservedJSON"))
        #expect(contents.contains(#"\"minimum\":7"#))
    }

    @Test("Unsupported assertions in every child role fail closed", arguments: nestedSchemas.map(\.0))
    func nestedUnsupportedAssertions(_ schema: String) {
        let child = #"{"type":"integer","unsupportedAssertion":7}"#
        #expect(throws: GenerationError.self) {
            try generateSchema(schema.replacingOccurrences(of: "CHILD", with: child))
        }
    }

    @Test(
        "Unconstrained child schemas retain ordinary typed generation",
        arguments: [nestedSchemas[0].0, nestedSchemas[2].0, nestedSchemas[4].0])
    func unconstrainedChildren(_ schema: String) throws {
        let contents = try generateSchema(schema.replacingOccurrences(of: "CHILD", with: #"{"type":"integer"}"#))
        #expect(!contents.contains("JSONSchemaPlan"))
        #expect(!contents.contains("PreservedJSON"))
        #expect(contents.contains("Int"))
    }

    @Test func customYAMLTagsAreRejectedInEveryRole() throws {
        for input in ["!custom {minimum: 1}", "!custom [1, 2]", "!custom minimum: 1", "minimum: !custom 1"] {
            #expect(throws: (any Error).self) { try losslessYAMLJSON(input) }
        }
        #expect(try losslessYAMLJSON("!!map {minimum: 1}") == Data(#"{"minimum":1}"#.utf8))
        #expect(try losslessYAMLJSON("!!seq [1, 2]") == Data("[1,2]".utf8))
    }

    @Test func exactConstantsAndYAML() throws {
        let yaml = """
            openapi: 3.0.3
            paths: {}
            components:
              schemas:
                Value:
                  type: number
                  minimum: 900719925474099312345678901234567890
                  maximum: 1e999999999999999999999
            """
        let document = try decodeOpenAPIDocument(from: Data(yaml.utf8), sourceExtension: "yaml")
        let files = try CodeGenerator(moduleName: "Test").generate(from: document)
        #expect(files[0].contents.contains("900719925474099312345678901234567890"))
        #expect(files[0].contents.contains("1e999999999999999999999"))
        #expect(files[0].contents.contains("JSONSchemaPlan"))
        let again = try CodeGenerator(moduleName: "Test").generate(from: document)
        #expect(files.map(\.filename) == again.map(\.filename))
        #expect(files.map(\.contents) == again.map(\.contents))
    }

    @Test(arguments: [".nan", "0xFF", ".inf"])
    func unsupportedYAMLNumbers(_ value: String) {
        #expect(throws: (any Error).self) { try losslessYAMLJSON("minimum: \(value)") }
    }
}
