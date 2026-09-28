import Foundation
import Testing

@testable import InnoNetwork

@Suite("Compiled JSON schema constraints")
struct JSONSchemaPlanTests {
    func plan(_ text: String) throws -> JSONSchemaPlan {
        try JSONSchemaPlan(schema: PreservedJSON(data: Data(text.utf8)))
    }
    func json(_ text: String) throws -> PreservedJSON { try PreservedJSON(data: Data(text.utf8)) }

    @Test(arguments: [
        (#"{"minimum":9007199254740993}"#, "9007199254740992", false),
        (#"{"minimum":9007199254740993}"#, "9007199254740993.0", true),
        (#"{"maximum":1e999999999999999999999999}"#, "1e999999999999999999999998", true),
        (#"{"maximum":1e999999999999999999999999}"#, "2e999999999999999999999999", false),
        (#"{"minimum":-1e999999999999999999999999}"#, "-2e999999999999999999999999", false),
        (#"{"minimum":1,"exclusiveMinimum":true}"#, "1.00", false),
        (#"{"maximum":1,"exclusiveMaximum":true}"#, "0.99999999999999999999999", true),
        (#"{"multipleOf":0.01}"#, "4.02", true),
        (#"{"multipleOf":0.01}"#, "4.021", false),
        (#"{"multipleOf":3}"#, "1e999999999999999999999", false),
        (#"{"multipleOf":8}"#, "1e999999999999999999999", true),
        (#"{"multipleOf":0.003}"#, "-0.012", true),
        (#"{"enum":[0]}"#, "-0e999999999999999999", true),
        (#"{"enum":[{"a":[1,true]}]}"#, #"{"a":[1.0,true]}"#, true),
        (#"{"enum":[1]}"#, "true", false),
        (#"{"enum":["é"]}"#, #""e\u0301""#, false),
        (#"{"enum":[{"é":1}]}"#, #"{"e\u0301":1}"#, false),
        (#"{"minLength":2,"maxLength":2}"#, #""e\u0301""#, true),
        (#"{"maxLength":1}"#, #""😀""#, true),
        (#"{"minItems":2,"maxItems":3}"#, "[1]", false),
        (#"{"minProperties":1,"maxProperties":1}"#, "{}", false),
        (#"{"minProperties":1,"maxProperties":1}"#, #"{"x":null}"#, true),
    ])
    func constraints(_ schema: String, _ value: String, _ expected: Bool) throws {
        #expect(try plan(schema).matches(json(value)) == expected)
    }

    @Test func matchingAndBudgets() throws {
        let schema = try plan(#"{"anyOf":[{"minimum":1},{"enum":[1.0]},{"type":"string"}]}"#)
        #expect(try schema.matchingAlternatives(json("1")) == [0, 1])
        #expect(throws: JSONProcessingError.resourceLimit) {
            try schema.matchingAlternatives(json("1"), limits: .init(maximumValidationWork: 2))
        }
        #expect(throws: JSONProcessingError.invalidSchema) { try plan(#"{"anyOf":[{}, {"multipleOf":0}]}"#) }
        #expect(throws: JSONProcessingError.unsupportedSchema) { try plan(#"{"anyOf":[{}, {"unknown":true}]}"#) }
        #expect(throws: JSONProcessingError.invalidSchema) { try plan(#"{"minLength":-1}"#) }
    }

    @Test func integerMultiplesMatchArithmeticOracle() throws {
        for divisor in 1...25 {
            let schema = try plan("{\"multipleOf\":\(divisor)}")
            for value in -75...75 { #expect(try schema.matches(json(String(value))) == (value % divisor == 0)) }
        }
    }
}
