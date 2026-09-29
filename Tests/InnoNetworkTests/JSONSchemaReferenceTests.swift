import Foundation
import Testing

@testable import InnoNetwork

@Suite("Compiled local recursive schemas")
struct JSONSchemaReferenceTests {
    func json(_ string: String) throws -> PreservedJSON { try PreservedJSON(data: Data(string.utf8)) }

    @Test func fragmentDecodingPrecedesPointerDecoding() throws {
        for prefix in ["#/$defs/", "#/components/schemas/"] {
            for (token, acceptsString) in [
                ("a%20b", true), ("a%2520b", false), ("a~1b", true), ("a%7E1b", true),
                ("a~0b", true), ("a%2Bb", true),
            ] {
                let definitions = [
                    "a b": try json(#"{"type":"string"}"#), "a%20b": try json(#"{"type":"integer"}"#),
                    "a/b": try json(#"{"type":"string"}"#), "a~b": try json(#"{"type":"string"}"#),
                    "a+b": try json(#"{"type":"string"}"#),
                ]
                let definitionBytes = Dictionary(
                    uniqueKeysWithValues: definitions.map { ($0.key, String(decoding: $0.value.data, as: UTF8.self)) })
                // Use JSONSerialization only to quote keys; schema bytes retain their meaning.
                let defs = try JSONSerialization.data(
                    withJSONObject: definitionBytes.mapValues { try JSONSerialization.jsonObject(with: Data($0.utf8)) })
                let ref = String(decoding: try JSONEncoder().encode(prefix + token), as: UTF8.self)
                let schema = try json("{\"$ref\":\(ref),\"$defs\":\(String(decoding: defs, as: UTF8.self))}")
                let plan = try JSONSchemaPlan(schema: schema, definitions: definitions, dialect: .jsonSchema202012)
                #expect(try plan.matches(json(#""ok""#)) == acceptsString)
                #expect(try plan.matches(json("1")) != acceptsString)
            }
        }
    }

    @Test func referenceNamesUseExactCodePoints() throws {
        let definition = try json(#"{"type":"string"}"#)
        let decomposed = "e\u{0301}"
        for (name, token) in [("é", "%C3%A9"), (decomposed, "e%CC%81")] {
            let schema = try PreservedJSON(data: JSONEncoder().encode(["$ref": "#/components/schemas/" + token]))
            let plan = try JSONSchemaPlan(schema: schema, definitions: [name: definition])
            #expect(try plan.matches(json(#""ok""#)))
            let other = name.utf8.elementsEqual("é".utf8) ? decomposed : "é"
            #expect(throws: JSONProcessingError.unsupportedSchema) {
                try JSONSchemaPlan(schema: schema, definitions: [other: definition])
            }
        }
        for token in ["bad%", "bad%2", "%FF", "%C0%AF", "a%2Fb", "a~2b"] {
            let schema = try PreservedJSON(data: JSONEncoder().encode(["$ref": "#/components/schemas/" + token]))
            #expect(throws: JSONProcessingError.unsupportedSchema) {
                try JSONSchemaPlan(schema: schema, definitions: [token: definition, "a/b": definition])
            }
        }
    }

    @Test func selfAndMutualRecursion() throws {
        let a = try json(
            ##"{"type":"object","properties":{"next":{"$ref":"#/components/schemas/B"},"value":{"type":"integer"}},"required":["value"]}"##
        )
        let b = try json(##"{"type":"object","properties":{"next":{"$ref":"#/components/schemas/A"}}}"##)
        let plan = try JSONSchemaPlan(schema: a, definitions: ["A": a, "B": b])
        #expect(try plan.matches(json(#"{"value":1,"next":{"next":{"value":2}}}"#)))
        #expect(try !plan.matches(json(#"{"value":1,"next":{"next":{"value":"bad"}}}"#)))
        #expect(throws: JSONProcessingError.resourceLimit) {
            try plan.matches(json(#"{"value":1,"next":{"next":{"value":2}}}"#), limits: .init(maximumDepth: 3))
        }
    }

    @Test func recursiveAnyOfAndConcurrentCalls() async throws {
        let tree = try json(
            ##"{"anyOf":[{"type":"integer"},{"type":"array","items":{"$ref":"#/components/schemas/Tree"}}]}"##)
        let plan = try JSONSchemaPlan(schema: tree, definitions: ["Tree": tree])
        let data = try json("[1,[2,[3]]]")
        #expect(try plan.matchingAlternatives(data) == [1])
        #expect(try !plan.matches(json(#"[1,["bad"]]"#)))
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 { group.addTask { try plan.matches(data) } }
            for try await result in group { #expect(result) }
        }
    }

    @Test func zeroProgressAndInvalidReferencesFailCompilation() throws {
        for source in [
            ##"{"$ref":"#/components/schemas/A"}"##,
            ##"{"anyOf":[{}, {"$ref":"#/components/schemas/A"}]}"##,
        ] {
            let a = try json(source)
            #expect(throws: JSONProcessingError.unsupportedSchema) {
                try JSONSchemaPlan(schema: a, definitions: ["A": a])
            }
        }
        for reference in [
            "https://example.com/schema", "file:///tmp/schema", "#/components/schemas/Missing",
            "#/components/schemas/A~2",
        ] {
            let schema = try PreservedJSON(data: JSONEncoder().encode(["$ref": reference]))
            #expect(throws: JSONProcessingError.unsupportedSchema) { try JSONSchemaPlan(schema: schema) }
        }
    }
}
