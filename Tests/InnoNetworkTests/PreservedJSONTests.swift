import Foundation
import Testing

@testable import InnoNetwork

@Suite("Preserved JSON and bounded schema validation")
struct PreservedJSONTests {
    private func document(_ text: String, limits: JSONProcessingLimits = .init()) throws -> PreservedJSON {
        try PreservedJSON(data: Data(text.utf8), limits: limits)
    }

    @Test("Unknown fields, large numeric lexemes and whitespace round-trip exactly")
    func preservation() throws {
        let text =
            #" {"value":123456789012345678901234567890123456789012345678901234567890,"extra":[-0.00,1e9999999999999999999999,1e-99999999999999999999,"\uD83D\uDE00"]} "#
        let value = try document(text)
        #expect(value.data == Data(text.utf8))
        #expect(try JSONSchema.object(properties: [:], required: [], allowsAdditionalProperties: true).matches(value))
        #expect(try !JSONSchema.object(properties: [:], required: [], allowsAdditionalProperties: false).matches(value))
    }

    @Test("Malformed JSON, duplicate keys and invalid Unicode are rejected")
    func invalidJSON() {
        for text in [
            "", " ", "01", "-01", "+1", "1.", ".1", "1e", "1e+", "NaN", "Infinity", "true false",
            "[1,]", "{\"a\":1,}", "[", "{", "\"a\n\"", #""\uD800""#, #""\uDC00""#,
            #""\uD800\u0041""#, #""\q""#, #"{"a":1,"\u0061":2}"#,
            #"{"é":1,"e\u0301":2}"#,
        ] {
            #expect(throws: JSONProcessingError.self) { try document(text) }
        }
        #expect(throws: JSONProcessingError.self) {
            try PreservedJSON(data: Data([34, 0xFF, 34]))
        }
        #expect(throws: JSONProcessingError.self) {
            try PreservedJSON(data: Data([34, 0xED, 0xA0, 0x80, 34]))
        }
    }

    @Test("Integer matching uses decimal mathematics rather than binary rounding")
    func integerMatching() throws {
        for text in [
            "0", "-0.000e-99999999999999", "1.0", "1e3", "10e-1", "100.00e-2",
            "9999999999999999999999999999999999999999999999999999999999999999", "1e9999999999999999",
        ] {
            #expect(try JSONSchema.integer.matches(document(text)))
        }
        for text in [
            "0.1", "1e-1", "100e-3", "1.000000000000000000000000000000000000000000001",
            "1e-999999999999999999999", "true", "\"1\"", "null",
        ] {
            #expect(try !JSONSchema.integer.matches(document(text)))
        }
    }

    @Test("Required nullable fields and multiple alternatives retain their distinct semantics")
    func alternatives() throws {
        let first = JSONSchema.object(
            properties: ["a": .nullable(.integer)], required: ["a"], allowsAdditionalProperties: true)
        let second = JSONSchema.object(properties: ["b": .string], required: ["b"], allowsAdditionalProperties: true)
        #expect(try !first.matches(document("{}")))
        #expect(try first.matches(document(#"{"a":null}"#)))
        #expect(try JSONSchema.matchingAlternatives([first, second], document: document(#"{"a":1}"#)) == [0])
        #expect(
            try JSONSchema.matchingAlternatives(
                [first, second], document: document(#"{"a":null,"b":"yes","unknown":1}"#)) == [0, 1])
        #expect(throws: JSONProcessingError.noMatchingSchema) {
            try JSONSchema.matchingAlternatives([first, second], document: document("{}"))
        }
        #expect(try JSONSchema.array(items: .boolean).matches(document("[true,false]")))
        #expect(try !JSONSchema.array(items: .boolean).matches(document("[true,1]")))
    }

    @Test("All resource limits are enforced at and across branches")
    func limits() throws {
        #expect(try document("[0]", limits: .init(maximumBytes: 3, maximumDepth: 2, maximumNodes: 2)).data.count == 3)
        for limits in [JSONProcessingLimits(maximumBytes: 2), .init(maximumDepth: 1), .init(maximumNodes: 1)] {
            #expect(throws: JSONProcessingError.resourceLimit) { try document("[0]", limits: limits) }
        }
        for limits in [
            JSONProcessingLimits(maximumBytes: 0), .init(maximumDepth: 129), .init(maximumNodes: Int.max),
            .init(maximumValidationWork: -1),
        ] {
            #expect(throws: JSONProcessingError.invalidLimits) { try document("0", limits: limits) }
        }
        let value = try document("1")
        #expect(throws: JSONProcessingError.resourceLimit) {
            try JSONSchema.matchingAlternatives(
                [.number, .integer], document: value, limits: .init(maximumValidationWork: 4))
        }
        #expect(
            try JSONSchema.matchingAlternatives(
                [.number, .integer], document: value, limits: .init(maximumValidationWork: 5)) == [0, 1])
        #expect(throws: JSONProcessingError.resourceLimit) {
            try JSONSchema.anyOf([.number, .array(items: .array(items: .string))]).matches(
                value, limits: .init(maximumDepth: 2))
        }
        #expect(throws: JSONProcessingError.resourceLimit) {
            try JSONSchema.number.matches(
                value, limits: .init(maximumBytes: 1, maximumNodes: 1, maximumValidationWork: 1))
        }
    }

    @Test("Typed views do not alter the raw document or claim schema validation")
    func typedView() throws {
        struct View: Decodable { let value: Int }
        let value = try document(#"{"value":1,"unknown":999999999999999999999999999999999999999999999999999}"#)
        #expect(try value.decode(View.self).value == 1)
        #expect(value.data.contains(Data("unknown".utf8)))
        #expect(throws: (any Error).self) { try document("1e99999").decode(Double.self) }
    }
}
