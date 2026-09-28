import Foundation
import Testing

@testable import openapi_to_innonetwork

@Suite("Preserved anyOf generation")
struct AnyOfTests {
    private func generate(
        branch: String = #"{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]}"#,
        extra: String = "", paths: String = "{}"
    ) throws -> [GeneratedFile] {
        let json =
            ##"{"paths":\##(paths),"components":{"schemas":{"Choice":{"anyOf":[{"$ref":"#/components/schemas/A"},{"$ref":"#/components/schemas/B"}]},"A":\##(branch),"B":{"type":"string"}\##(extra)}}}"##
        return try CodeGenerator(moduleName: "AnyOf").generate(
            from: JSONDecoder().decode(OpenAPIDocument.self, from: Data(json.utf8)))
    }

    @Test("Named references generate all-match preserved wrappers and throwing typed views")
    func valid() throws {
        let files = try generate()
        let choice = try #require(files.first { $0.filename == "Choice.swift" }?.contents)
        #expect(choice.contains("public let json: PreservedJSON"))
        #expect(choice.contains("public let matchingBranches: [Int]"))
        #expect(choice.contains("func asBranch0() throws -> A?"))
        #expect(choice.contains("JSONSchema.matchingAlternatives"))
        #expect(choice.contains("allowsAdditionalProperties: true"))
        #expect(!choice.contains("try?"))
    }

    @Test(
        "Unimplemented constraints fail rather than disappearing from validation",
        arguments: [
            "enum", "minimum", "maximum", "pattern", "minLength", "maxItems", "uniqueItems", "not", "$dynamicRef",
            "readOnly", "writeOnly",
        ])
    func unsupported(_ key: String) {
        #expect(throws: GenerationError.self) { try generate(branch: "{\"type\":\"string\",\"\(key)\":0}") }
    }

    @Test("Constraints on optional properties, reference siblings and nested schemas fail closed")
    func invalidNested() {
        for branch in [
            #"{"type":"object","properties":{"optional":{"type":"string","pattern":"a"}}}"#,
            #"{"type":"integer","format":"int64"}"#,
            #"{"type":"object","additionalProperties":{"type":"string"}}"#,
            #"{"type":"object","nullable":null}"#,
            ##"{"$ref":"#/components/schemas/B","nullable":true}"##,
            #"{"allOf":[{"type":"object"}]}"#,
            #"{"type":"object","required":["a","a"]}"#,
            #"{"type":"array"}"#,
        ] {
            #expect(throws: GenerationError.self) { try generate(branch: branch) }
        }
    }

    @Test("Recursive validation graphs and unresolved/external references are rejected")
    func recursion() {
        for reference in [
            "#/components/schemas/A", "#/components/schemas/Choice", "#/components/schemas/Missing", "other.json#/A",
        ] {
            #expect(throws: GenerationError.self) {
                try generate(branch: #"{"type":"object","properties":{"next":{"$ref":""# + reference + #""}}}"#)
            }
        }
    }

    @Test("Nested anyOf use selects preserved transport; bodyless methods reject JSON bodies")
    func operations() throws {
        let paths =
            ##"{"/choice":{"post":{"operationId":"sendChoice","requestBody":{"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Choice"}}}},"responses":{"204":{}}}}}"##
        let text = try #require(generate(paths: paths).first { $0.filename == "SendChoice.swift" }?.contents)
        #expect(text.contains(".preservedJSON(limits: .init())"))
        #expect(text.contains("return EmptyResponse()"))
        #expect(throws: GenerationError.self) {
            try generate(paths: paths.replacingOccurrences(of: "\"post\"", with: "\"get\""))
        }
        let extra =
            ##", "Wrapper":{"type":"object","properties":{"values":{"type":"array","items":{"$ref":"#/components/schemas/Choice"}}}}"##
        let get =
            ##"{"/choice":{"get":{"operationId":"readChoice","responses":{"200":{"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Wrapper"}}}}}}}}"##
        #expect(
            try generate(extra: extra, paths: get).first { $0.filename == "ReadChoice.swift" }!.contents.contains(
                "PreservedJSONCoding.decode"))
    }

    @Test("Annotations do not alter validation; false additionalProperties does")
    func annotations() throws {
        let files = try generate(
            branch:
                #"{"type":"object","title":"label","description":"text","additionalProperties":false,"properties":{"n":{"type":"number","nullable":true}}}"#
        )
        let choice = try #require(files.first { $0.filename == "Choice.swift" }?.contents)
        #expect(choice.contains("allowsAdditionalProperties: false"))
        #expect(choice.contains(".nullable(.number)"))
    }

    @Test("Schema expansion and branch counts are bounded")
    func bounds() {
        var branch = #"{"type":"string"}"#
        for _ in 0..<40 { branch = #"{"type":"array","items":"# + branch + "}" }
        #expect(throws: GenerationError.self) { try generate(branch: branch) }
        let choice = Schema(anyOf: Array(repeating: Schema(ref: "#/components/schemas/A"), count: 33))
        #expect(throws: GenerationError.self) { try CodeGenerator(moduleName: "AnyOf").validateAnyOfShape(choice) }
    }

    @Test("The OpenAPI 3.1 dialect is not silently interpreted as 3.0")
    func dialect() throws {
        let choice = Schema(anyOf: [Schema(ref: "#/components/schemas/A"), Schema(ref: "#/components/schemas/B")])
        let document = OpenAPIDocument(
            paths: [:],
            components: Components(schemas: [
                "Choice": choice, "A": Schema(type: "string"), "B": Schema(type: "number"),
            ]), openapi: "3.1.0")
        #expect(throws: GenerationError.self) { try CodeGenerator(moduleName: "AnyOf").generate(from: document) }
    }
}
