import Foundation
import Testing

@testable import openapi_to_innonetwork

@Suite("Generator contract extensions")
struct ContractExtensionTests {
    private func generate(_ json: String) throws -> [GeneratedFile] {
        try CodeGenerator(moduleName: "Contracts").generate(
            from: JSONDecoder().decode(OpenAPIDocument.self, from: Data(json.utf8)))
    }

    @Test("path parameters bind safely and operation parameters override path defaults")
    func pathBinding() throws {
        let files = try generate(
            #"""
            {"paths":{"/items/{id}":{"parameters":[{"name":"id","in":"path","required":true,"schema":{"type":"string"}}],
            "get":{"operationId":"getItem","parameters":[{"name":"id","in":"path","required":true,"schema":{"type":"integer","format":"int64"}}]}}}}
            """#)
        let text = try #require(files.first?.contents)
        #expect(text.contains("public init(path_id: Int64)"))
        #expect(text.contains(#"\(EndpointPathEncoding.percentEncodedSegment(path_id))"#))
    }

    @Test("security inherits, overrides and never silently weakens unsupported requirements")
    func security() throws {
        let text = #"""
            {"components":{"securitySchemes":{"session":{"type":"http","scheme":"bearer"}}},
             "security":[{"session":[]}],"paths":{"/a":{"get":{"operationId":"secure"}},
             "/b":{"get":{"operationId":"public","security":[]}},
             "/c":{"get":{"operationId":"optional","security":[{},{"session":[]}]}}}}
            """#
        let files = try generate(text)
        #expect(files.first { $0.filename == "Secure.swift" }?.contents.contains("{ .required }") == true)
        #expect(files.first { $0.filename == "Public.swift" }?.contents.contains("{ .anonymous }") == true)
        #expect(files.first { $0.filename == "Optional.swift" }?.contents.contains("{ .optional }") == true)
        #expect(throws: GenerationError.self) {
            try generate(text.replacingOccurrences(of: "\"bearer\"", with: "\"basic\""))
        }
        #expect(throws: GenerationError.self) {
            try generate(text.replacingOccurrences(of: "\"session\":[]", with: "\"missing\":[]"))
        }
    }

    @Test("allOf conflicts and cycles are rejected")
    func invalidComposition() {
        for schemas in [
            #""A":{"allOf":[{"type":"object","properties":{"id":{"type":"integer"}}},{"type":"object","properties":{"id":{"type":"string"}}}]}"#,
            ##""A":{"allOf":[{"$ref":"#/components/schemas/A"}]}"##,
            #""A":{"oneOf":[{"type":"string"},{"type":"integer"}]}"#,
            #""A":{"anyOf":[{"type":"string"},{"type":"integer"}]}"#,
        ] {
            #expect(throws: GenerationError.self) {
                try generate(#"{"paths":{},"components":{"schemas":{"# + schemas + "}}}")
            }
        }
    }

    @Test("unbound, malformed, optional and unsupported parameter shapes fail")
    func invalidParameters() {
        for path in ["/a/{missing}", "/a/{id", "/a/}", "/a/{id}?x=1"] {
            let document = OpenAPIDocument(paths: [path: PathItem(get: Operation(operationId: "get"))])
            #expect(throws: GenerationError.self) { try CodeGenerator(moduleName: "API").generate(from: document) }
        }
        #expect(throws: GenerationError.self) {
            try generate(
                #"{"paths":{"/a/{id}":{"get":{"parameters":[{"name":"id","in":"path","required":false,"schema":{"type":"string"}}]}}}}"#
            )
        }
    }
}
