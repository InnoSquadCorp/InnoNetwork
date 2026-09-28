import Foundation
import Testing

@testable import openapi_to_innonetwork

@Suite("Lossless compiled schema generation")
struct CompiledSchemaTests {
    @Test func customYAMLTagsAreRejectedInEveryRole() throws {
        for input in ["!custom {minimum: 1}", "!custom [1, 2]", "!custom minimum: 1", "minimum: !custom 1"] {
            #expect(throws: (any Error).self) { try losslessYAMLJSON(input) }
        }
        #expect(try losslessYAMLJSON("!!map {minimum: 1}") == Data(#"{"minimum":1}"#.utf8))
        #expect(try losslessYAMLJSON("!!seq [1, 2]") == Data("[1,2]".utf8))
    }

    @Test func exactConstantsAndYAML() throws {
        let yaml = """
            openapi: 3.0.3
            paths: {}
            components:
              schemas:
                Value:
                  type: number
                  minimum: 900719925474099312345678901234567890
                  maximum: 1e999999999999999999999
            """
        let document = try decodeOpenAPIDocument(from: Data(yaml.utf8), sourceExtension: "yaml")
        let files = try CodeGenerator(moduleName: "Test").generate(from: document)
        #expect(files[0].contents.contains("900719925474099312345678901234567890"))
        #expect(files[0].contents.contains("1e999999999999999999999"))
        #expect(files[0].contents.contains("JSONSchemaPlan"))
        let again = try CodeGenerator(moduleName: "Test").generate(from: document)
        #expect(files.map(\.filename) == again.map(\.filename))
        #expect(files.map(\.contents) == again.map(\.contents))
    }

    @Test(arguments: [".nan", "0xFF", ".inf"])
    func unsupportedYAMLNumbers(_ value: String) {
        #expect(throws: (any Error).self) { try losslessYAMLJSON("minimum: \(value)") }
    }
}
