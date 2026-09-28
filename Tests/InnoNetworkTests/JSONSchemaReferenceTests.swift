import Foundation
import Testing

@testable import InnoNetwork

@Suite("Compiled local recursive schemas")
struct JSONSchemaReferenceTests {
    func json(_ string: String) throws -> PreservedJSON { try PreservedJSON(data: Data(string.utf8)) }

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
