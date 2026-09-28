import Foundation
import Testing

@testable import InnoNetwork

@Suite("Pinned official JSON Schema 2020-12 fixtures")
struct JSONSchemaOfficialTests {
    struct Group: Decodable {
        let description: String
        let schema: PreservedJSON
        let tests: [Example]
    }
    struct Example: Decodable {
        let description: String
        let data: PreservedJSON
        let valid: Bool
    }

    @Test(arguments: [
        "enum", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
        "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties", "type", "boolean_schema",
        "const", "required", "anyOf", "allOf",
    ])
    func official(_ file: String) throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/JSONSchema202012")
        let groups = try PreservedJSONCoding.decode(
            [Group].self, from: Data(contentsOf: directory.appendingPathComponent(file + ".json")))
        let expectedExamples = [
            "enum": 53, "minimum": 11, "maximum": 8, "exclusiveMinimum": 4,
            "exclusiveMaximum": 4, "multipleOf": 11, "minLength": 7, "maxLength": 7, "minItems": 6,
            "maxItems": 6, "minProperties": 10, "maxProperties": 10, "type": 80, "boolean_schema": 18,
            "const": 54, "required": 18, "anyOf": 18, "allOf": 30,
        ]
        #expect(groups.reduce(0) { $0 + $1.tests.count } == expectedExamples[file])
        for group in groups {
            let plan = try JSONSchemaPlan(schema: group.schema, dialect: .jsonSchema202012)
            for example in group.tests {
                #expect(
                    try plan.matches(example.data) == example.valid,
                    "\(file): \(group.description) / \(example.description)")
            }
        }
    }
}
