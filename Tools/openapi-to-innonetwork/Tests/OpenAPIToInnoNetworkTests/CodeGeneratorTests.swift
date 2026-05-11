import Foundation
import Testing

@testable import openapi_to_innonetwork

@Suite
struct CodeGeneratorTests {
    @Test
    func generatesOneFilePerOperation() throws {
        let document = OpenAPIDocument(paths: [
            "/users": PathItem(
                get: Operation(operationId: "getUser", summary: "Fetch a user."),
                post: nil,
                put: nil,
                patch: nil,
                delete: Operation(operationId: "deleteUser", summary: nil)
            )
        ])
        let generator = CodeGenerator(moduleName: "GitHub")

        let files = try generator.generate(from: document)

        #expect(files.count == 2)
        #expect(files.contains(where: { $0.filename == "GetUser.swift" }))
        #expect(files.contains(where: { $0.filename == "DeleteUser.swift" }))
    }

    @Test
    func generatedFileConformsToAPIDefinition() throws {
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

        let files = try generator.generate(from: document)
        let body = try #require(files.first?.contents)

        #expect(body.contains("import InnoNetwork"))
        #expect(body.contains("public struct HealthCheck: APIDefinition"))
        #expect(body.contains("public var path: String { \"/health\" }"))
        #expect(body.contains("public var method: HTTPMethod { .get }"))
    }

    @Test
    func sanitizesNonAlphanumericOperationId() throws {
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

        let files = try generator.generate(from: document)

        #expect(files.first?.filename == "ListUsersV1.swift")
    }

    @Test
    func fallsBackToMethodPathWhenOperationIdMissing() throws {
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

        let files = try generator.generate(from: document)
        let filename = try #require(files.first?.filename)

        #expect(filename.hasPrefix("Post"))
        #expect(filename.hasSuffix(".swift"))
    }

    @Test
    func pathTemplatesAreRejected() {
        let document = OpenAPIDocument(paths: [
            "/users/{id}": PathItem(
                get: Operation(operationId: "getUser", summary: nil),
                post: nil,
                put: nil,
                patch: nil,
                delete: nil
            )
        ])
        let generator = CodeGenerator(moduleName: "API")

        #expect(throws: GenerationError.self) {
            _ = try generator.generate(from: document)
        }
    }

    @Test
    func pathTemplateErrorIdentifiesPlaceholder() {
        let document = OpenAPIDocument(paths: [
            "/users/{userId}/posts/{postId}": PathItem(
                get: Operation(operationId: "getUserPost", summary: nil),
                post: nil,
                put: nil,
                patch: nil,
                delete: nil
            )
        ])
        let generator = CodeGenerator(moduleName: "API")

        do {
            _ = try generator.generate(from: document)
            Issue.record("expected path template error")
        } catch let error as GenerationError {
            // Description must call out the first placeholder so users can
            // fix the offending path immediately rather than guessing.
            #expect(error.description.contains("{userId}"))
            #expect(error.description.contains("/users/{userId}/posts/{postId}"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func emptyResponseForExplicit202And204() throws {
        let document = OpenAPIDocument(paths: [
            "/jobs": PathItem(
                get: nil,
                post: Operation(
                    operationId: "submitJob",
                    summary: nil,
                    responses: ["202": ResponseObject(description: nil, content: nil)]
                ),
                put: nil,
                patch: nil,
                delete: Operation(
                    operationId: "deleteJob",
                    summary: nil,
                    responses: ["204": ResponseObject(description: nil, content: nil)]
                )
            )
        ])
        let generator = CodeGenerator(moduleName: "API")

        let files = try generator.generate(from: document)
        let submit = try #require(files.first(where: { $0.filename == "SubmitJob.swift" })?.contents)
        let delete = try #require(files.first(where: { $0.filename == "DeleteJob.swift" })?.contents)

        #expect(submit.contains("public typealias APIResponse = EmptyResponse"))
        #expect(delete.contains("public typealias APIResponse = EmptyResponse"))
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

        let files = try generator.generate(from: document)
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
        #expect(!user.contains("CodingKeys"))
        #expect(!user.contains("Optional("))
        #expect(anyCodable.contains("public indirect enum AnyCodable: Codable, Sendable, Equatable"))
    }

    @Test
    func generatedSchemaPreservesOriginalKeysForSanitizedProperties() throws {
        let document = OpenAPIDocument(
            paths: [:],
            components: Components(schemas: [
                "User": Schema(
                    type: "object",
                    properties: [
                        "1st-name": Schema(type: "string"),
                        "Protocol": Schema(type: "string"),
                        "Type": Schema(type: "string"),
                        "class": Schema(type: "string"),
                        "display_name": Schema(type: "string"),
                        "user-id": Schema(type: "integer", format: "int64"),
                    ],
                    required: ["1st-name", "Protocol", "Type", "class", "display_name", "user-id"]
                )
            ])
        )
        let generator = CodeGenerator(moduleName: "API")

        let files = try generator.generate(from: document)
        let user = try #require(files.first(where: { $0.filename == "User.swift" })?.contents)

        #expect(user.contains("public var _1stName: String"))
        #expect(user.contains("public var Protocol_: String"))
        #expect(user.contains("public var Type_: String"))
        #expect(user.contains("public var class_: String"))
        #expect(user.contains("public var display_name: String"))
        #expect(user.contains("public var userId: Int64"))
        #expect(user.contains("private enum CodingKeys: String, CodingKey"))
        #expect(user.contains("case _1stName = \"1st-name\""))
        #expect(user.contains("case Protocol_ = \"Protocol\""))
        #expect(user.contains("case Type_ = \"Type\""))
        #expect(user.contains("case class_ = \"class\""))
        #expect(user.contains("case display_name"))
        #expect(user.contains("case userId = \"user-id\""))
    }

    @Test
    func rejectsSchemaPropertiesThatCollapseToTheSameSwiftIdentifier() {
        let document = OpenAPIDocument(
            paths: [:],
            components: Components(schemas: [
                "User": Schema(
                    type: "object",
                    properties: [
                        "class": Schema(type: "string"),
                        "class_": Schema(type: "string"),
                    ],
                    required: ["class", "class_"]
                )
            ])
        )
        let generator = CodeGenerator(moduleName: "API")

        do {
            _ = try generator.generate(from: document)
            Issue.record("expected duplicate Swift identifier error")
        } catch let error as GenerationError {
            #expect(error.description.contains("class"))
            #expect(error.description.contains("class_"))
            #expect(error.description.contains("Swift identifier 'class_'"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
