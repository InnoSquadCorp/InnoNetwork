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

    @Test
    func generatesSchemaPropertiesWithoutOptionalInterpolation() throws {
        let document = OpenAPIDocument(
            paths: [:],
            components: Components(schemas: [
                "User": Schema(
                    type: "object",
                    properties: [
                        "id": Schema(type: "integer", format: "int64"),
                        "metadata": Schema(type: "object"),
                        "name": Schema(type: "string"),
                        "profile": Schema(ref: "#/components/schemas/Profile"),
                        "tags": Schema(type: "array", items: Box(Schema(type: "string"))),
                    ],
                    required: ["id", "name", "profile"]
                )
            ])
        )
        let generator = CodeGenerator(moduleName: "API")

        let files = generator.generate(from: document)
        let user = try #require(files.first(where: { $0.filename == "User.swift" })?.contents)
        let anyCodable = try #require(files.first(where: { $0.filename == "AnyCodable.swift" })?.contents)

        #expect(user.contains("public var id: Int64"))
        #expect(user.contains("public var metadata: AnyCodable?"))
        #expect(user.contains("public var name: String"))
        #expect(user.contains("public var profile: Profile"))
        #expect(user.contains("public var tags: [String]?"))
        #expect(
            user.contains(
                "public init(id: Int64, metadata: AnyCodable? = nil, name: String, profile: Profile, tags: [String]? = nil)"
            ))
        #expect(!user.contains("Optional("))
        #expect(anyCodable.contains("public indirect enum AnyCodable: Codable, Sendable, Equatable"))
    }
}
