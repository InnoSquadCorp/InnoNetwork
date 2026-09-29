import Foundation
import Testing

@testable import InnoNetwork

@Suite("Lightweight schema exact property identity")
struct JSONSchemaIdentityTests {
    @Test(arguments: ["caf\u{00E9}", "cafe\u{0301}"])
    func requiredNamesAreExact(name: String) throws {
        let schema = JSONSchema.object(properties: [:], required: [name], allowsAdditionalProperties: true)
        let plan = try compiled(properties: [:], required: [name], additional: true)
        for key in ["caf\u{00E9}", "cafe\u{0301}", "other"] {
            let json = try document([key: 42])
            let expected = key.utf8.elementsEqual(name.utf8)
            #expect(try schema.matches(json) == expected)
            #expect(try schema.matches(json) == plan.matches(json))
        }
    }

    @Test(arguments: [false, true])
    func optionalPropertyIdentity(additional: Bool) throws {
        for name in ["caf\u{00E9}", "cafe\u{0301}"] {
            let schema = JSONSchema.object(
                properties: [name: .integer], required: [], allowsAdditionalProperties: additional)
            let plan = try compiled(properties: [name: ["type": "integer"]], required: [], additional: additional)
            for key in ["caf\u{00E9}", "cafe\u{0301}", "other"] {
                for validType in [true, false] {
                    let json = try document([key: validType ? 42 : "text"])
                    let exact = key.utf8.elementsEqual(name.utf8)
                    let expected = exact ? validType : additional
                    #expect(try schema.matches(json) == expected)
                    #expect(try schema.matches(json) == plan.matches(json))
                }
            }
        }
    }

    @Test func escapesAndAlternativesKeepSemanticIdentity() throws {
        let schema = JSONSchema.object(
            properties: ["café": .integer], required: ["café"], allowsAdditionalProperties: false)
        let literal = try PreservedJSON(data: Data(#"{"caf\u00e9":42}"#.utf8))
        #expect(try schema.matches(literal))
        let different = try PreservedJSON(data: Data(#"{"cafe\u0301":42}"#.utf8))
        let fallback = JSONSchema.object(properties: [:], required: [], allowsAdditionalProperties: true)
        #expect(try JSONSchema.matchingAlternatives([schema, fallback], document: different) == [1])
        #expect(throws: JSONProcessingError.resourceLimit) {
            try schema.matches(literal, limits: .init(maximumValidationWork: 1))
        }
    }

    private func document(_ value: [String: Any]) throws -> PreservedJSON {
        try PreservedJSON(data: JSONSerialization.data(withJSONObject: value))
    }

    private func compiled(properties: [String: Any], required: [String], additional: Bool) throws -> JSONSchemaPlan {
        try JSONSchemaPlan(
            schema: document([
                "type": "object", "properties": properties, "required": required, "additionalProperties": additional,
            ]))
    }
}
