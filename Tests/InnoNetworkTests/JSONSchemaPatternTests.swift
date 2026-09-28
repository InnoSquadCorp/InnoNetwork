import Foundation
import Testing

@testable import InnoNetwork

@Suite("Bounded schema pattern subset")
struct JSONSchemaPatternTests {
    func plan(_ pattern: String) throws -> JSONSchemaPlan {
        try JSONSchemaPlan(schema: PreservedJSON(data: JSONEncoder().encode(["pattern": pattern])))
    }
    func value(_ string: String) throws -> PreservedJSON { try PreservedJSON(data: JSONEncoder().encode(string)) }

    @Test(arguments: [
        ("abc", "xabcx", true), ("^abc$", "xabcx", false), ("^abc$", "abc\n", false),
        ("^.$", "😀", true), ("^.$", "e\u{301}", false), ("^.$", "\n", false),
        ("^[a-z]{2,4}$", "abc", true), ("^[a-z]{2,4}$", "abcde", false),
        (#"^\d+\.\d?$"#, "1.2", true), (#"^\d+\.\d?$"#, "a.2", false),
        ("a*b+c?", "b", true), ("a{0,}b", "aaab", true), ("a{2}", "aaa", true),
        ("[^0-9]+", "123!", true), ("[]", "x", false), ("[^]", "\n", true),
        (#"[\w-]+"#, "_ab-9", true), ("", "anything", true), ("^$", "", true),
    ])
    func expectedMatches(_ pattern: String, _ text: String, _ expected: Bool) throws {
        #expect(try plan(pattern).matches(value(text)) == expected)
    }

    @Test(arguments: ["(a+)+$", "a|b", "(?=a)", #"(a)\1"#, #"\p{L}"#, #"\u0061"#, "a??", "a{3,2}", "[z-a]", #"\-"#])
    func unsupportedConstructs(_ pattern: String) {
        #expect(throws: JSONProcessingError.unsupportedSchema) { try plan(pattern) }
    }

    @Test func differentialASCIIControls() throws {
        for pattern in ["a*b", "^a+b?$", "[a-c]{1,3}", "^[^ab]+$", #"\d\w?"#] {
            let compiled = try plan(pattern)
            let oracle = try NSRegularExpression(pattern: pattern)
            for string in ["", "a", "aaab", "ab", "d", "9_", "abc", "abc\n"] {
                let expected = oracle.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
                #expect(try compiled.matches(value(string)) == expected)
            }
        }
    }

    @Test func sharedWorkAndFormatPolicy() throws {
        let compiled = try plan("a*a*a*a*a*b")
        #expect(throws: JSONProcessingError.resourceLimit) {
            try compiled.matches(value(String(repeating: "a", count: 100)), limits: .init(maximumValidationWork: 300))
        }
        #expect(try !compiled.matches(value(String(repeating: "a", count: 100))))
        #expect(throws: JSONProcessingError.resourceLimit) { try plan("a{4096}") }
        let annotation = try JSONSchemaPlan(
            schema: PreservedJSON(data: Data(#"{"type":"string","format":"email"}"#.utf8)))
        #expect(try annotation.matches(value("not an email")))
    }
}
