import Foundation
import Testing

@testable import openapi_to_innonetwork

@Suite
struct CodeGeneratorTests {
    @Test
    func generatesOneFilePerOperation() {
        let document = OpenAPIDocument(paths: [
            "/users/{id}": PathItem(
                get: Operation(operationId: "getUser", summary: "Fetch a user."),
                post: nil,
                put: nil,
                patch: nil,
                delete: Operation(operationId: "deleteUser", summary: nil)
            )
        ])
        let generator = CodeGenerator(moduleName: "GitHub")

        let files = generator.generate(from: document)

        #expect(files.count == 2)
        #expect(files.contains(where: { $0.filename == "GetUser.swift" }))
        #expect(files.contains(where: { $0.filename == "DeleteUser.swift" }))
    }

    @Test
    func generatedFileConformsToAPIDefinition() {
        let document = OpenAPIDocument(paths: [
            "/health": PathItem(
                get: Operation(operationId: "healthCheck", summary: nil),
                post: nil,
                put: nil,
                patch: nil,
                delete: nil
            )
        ])
        let generator = CodeGenerator(moduleName: "GitHub")

        let files = generator.generate(from: document)
        let body = try? #require(files.first?.contents)

        #expect(body?.contains("import InnoNetwork") == true)
        #expect(body?.contains("public struct HealthCheck: APIDefinition") == true)
        #expect(body?.contains("public var path: String { \"/health\" }") == true)
        #expect(body?.contains("public var method: HTTPMethod { .get }") == true)
    }

    @Test
    func sanitizesNonAlphanumericOperationId() {
        let document = OpenAPIDocument(paths: [
            "/v1/users": PathItem(
                get: Operation(operationId: "list-users.v1", summary: nil),
                post: nil,
                put: nil,
                patch: nil,
                delete: nil
            )
        ])
        let generator = CodeGenerator(moduleName: "API")

        let files = generator.generate(from: document)

        #expect(files.first?.filename == "ListUsersV1.swift")
    }

    @Test
    func fallsBackToMethodPathWhenOperationIdMissing() {
        let document = OpenAPIDocument(paths: [
            "/posts": PathItem(
                get: nil,
                post: Operation(operationId: nil, summary: nil),
                put: nil,
                patch: nil,
                delete: nil
            )
        ])
        let generator = CodeGenerator(moduleName: "API")

        let files = generator.generate(from: document)
        let filename = try? #require(files.first?.filename)

        #expect(filename?.hasPrefix("Post") == true)
        #expect(filename?.hasSuffix(".swift") == true)
    }
}
