import Foundation
import Testing

@testable import InnoNetwork

@Suite("Explicit JSON schema dialect contracts")
struct JSONSchemaDialectTests {
    func json(_ text: String) throws -> PreservedJSON { try PreservedJSON(data: Data(text.utf8)) }

    @Test func refsHaveConjunctiveSiblings() throws {
        let schema = try json(
            ##"{"$defs":{"Positive":{"type":"number","minimum":1}},"$ref":"#/$defs/Positive","exclusiveMinimum":2}"##)
        let plan = try JSONSchemaPlan(schema: schema, dialect: .jsonSchema202012)
        #expect(try plan.matches(json("3")))
        #expect(try !plan.matches(json("2")))
        #expect(try !plan.matches(json(#""3""#)))
        #expect(throws: JSONProcessingError.unsupportedSchema) { try JSONSchemaPlan(schema: schema) }
    }

    @Test func unsupportedDialectsAndKeywordsFail() throws {
        for schema in [
            ##"{"$schema":"https://example.com/dialect"}"##,
            ##"{"$dynamicRef":"#node"}"##, #"{"unevaluatedProperties":false}"#,
            #"{"nullable":true}"#, #"{"not":{}}"#, #"{"items":[{}]}"#,
            #"{"additionalProperties":{"type":"string"}}"#,
        ] {
            #expect(throws: (any Error).self) { try JSONSchemaPlan(schema: json(schema), dialect: .jsonSchema202012) }
        }
        #expect(throws: JSONProcessingError.invalidSchema) { try JSONSchemaPlan(schema: json("true")) }
        #expect(throws: JSONProcessingError.invalidSchema) {
            try JSONSchemaPlan(schema: json(#"{"exclusiveMinimum":true}"#), dialect: .jsonSchema202012)
        }
    }

    @Test func typeNullConstAndOneOf() throws {
        let plan = try JSONSchemaPlan(
            schema: json(#"{"type":["number","null"],"minimum":1}"#), dialect: .jsonSchema202012)
        #expect(try plan.matches(json("null")))
        #expect(try !plan.matches(json("0")))
        let conflict = try JSONSchemaPlan(schema: json(#"{"enum":[1],"const":2}"#), dialect: .jsonSchema202012)
        #expect(try !conflict.matches(json("1")))
        let exclusive = try JSONSchemaPlan(
            schema: json(#"{"oneOf":[{"type":"integer"},{"type":"number"}]}"#), dialect: .jsonSchema202012)
        #expect(try !exclusive.matches(json("1")))
        #expect(try exclusive.matches(json("1.5")))
        #expect(try !exclusive.matches(json("null")))
    }

    @Test func modernLocalRecursionAndSharedBudgets() throws {
        let recursive = try JSONSchemaPlan(
            schema: json(
                ##"{"$defs":{"Node":{"anyOf":[{"type":"null"},{"type":"object","required":["next"],"properties":{"next":{"$ref":"#/$defs/Node"}}}]}},"$ref":"#/$defs/Node"}"##
            ), dialect: .jsonSchema202012)
        #expect(try recursive.matches(json(#"{"next":{"next":null}}"#)))
        #expect(try !recursive.matches(json(#"{"next":0}"#)))
        #expect(throws: JSONProcessingError.resourceLimit) {
            try recursive.matches(json(#"{"next":{"next":null}}"#), limits: .init(maximumValidationWork: 3))
        }
        for applicator in ["allOf", "oneOf"] {
            let schema =
                "{\"$defs\":{\"Loop\":{\"\(applicator)\":[{\"$ref\":\"#/$defs/Loop\"}]}},\"$ref\":\"#/$defs/Loop\"}"
            #expect(throws: JSONProcessingError.unsupportedSchema) {
                try JSONSchemaPlan(schema: json(schema), dialect: .jsonSchema202012)
            }
        }
    }
}
