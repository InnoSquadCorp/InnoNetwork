#if Macros
import InnoNetworkMacroSupport
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import Testing

@Suite("Companion encoded endpoint analysis")
struct EncodedEndpointExpansionTests {
    private let policyNames: Set<String> = ["headers", "timeout", "retryPolicy"]

    @Test func bodyQueryRouteAccessAndPoliciesAreVisibleToCompanion() throws {
        let result = try analyze(
            """
            public struct Endpoint {
                typealias APIResponse = Response
                let `id`: String
                let body: Body
                let query: Query
                var headers: HTTPHeaders { [:] }
                let timeout: Double
            }
            """, method: ".post", path: "/items/{id}", auth: ".required")
        #expect(result.typeName == "Endpoint")
        #expect(result.accessPrefix == "public ")
        #expect(result.methodExpression == ".post")
        #expect(result.authenticationExpression == ".required")
        #expect(result.hasBody && result.hasQuery)
        #expect(result.presentPolicies == ["headers", "timeout"])
        #expect(result.pathWitness.contains("id"))
        #expect(result.pathWitness.contains("EndpointPathEncoding.percentEncodedSegment"))
        #expect(result.pathWitness.contains("self.`id`"))
    }

    @Test(arguments: ["get", "head", "post", "put", "patch", "delete", "options", "trace"])
    func emptyEndpointsAndQualifiedMethods(method: String) throws {
        let result = try analyze(
            "struct Endpoint { typealias APIResponse = Response }", method: "InnoNetwork.HTTPMethod.\(method)")
        #expect(result.accessPrefix == "internal ")
        #expect(result.methodExpression == ".\(method)")
        #expect(result.authenticationExpression == ".anonymous")
        #expect(!result.hasBody && !result.hasQuery)
        #expect(result.presentPolicies.isEmpty)
        #expect(result.pathWitness.contains("\"/\""))
    }

    @Test(arguments: [
        "struct Endpoint {}",
        "struct Endpoint: EncodedAPIDefinition { typealias APIResponse = Response }",
        "struct Endpoint: InnoNetwork.APIDefinition { typealias APIResponse = Response }",
        "struct Endpoint { typealias APIResponse = Response; typealias Parameter = Body }",
        "struct Endpoint { typealias APIResponse = Response; let parameters: String }",
        "struct Endpoint { typealias APIResponse = Response; func makeEncodedRequest() {} }",
        "struct Endpoint { typealias APIResponse = Response; let method: String }",
        "struct Endpoint { typealias APIResponse = Response; let path: String }",
        "struct Endpoint { typealias APIResponse = Response; let sessionAuthentication: String }",
        "struct Endpoint { typealias APIResponse = Response; let body = Body() }",
        "struct Endpoint { typealias APIResponse = Response; let extra: String }",
        "struct Endpoint { typealias APIResponse = Response; static let headers: HTTPHeaders = [:] }",
        "struct Endpoint { typealias APIResponse = Response; lazy var retryPolicy: Policy = Policy() }",
        "struct Endpoint { typealias APIResponse = Response; let (body, query): (Body, Query) }",
        """
        struct Endpoint {
            typealias APIResponse = Response
            #if DEBUG
            let body: Body
            #endif
        }
        """,
    ])
    func invalidDeclarationsUseTheCompanionDiagnostic(declaration: String) {
        expectCompanionDiagnostic { try analyze(declaration, method: ".post") }
    }

    @Test(arguments: ["get", "head", "trace"])
    func bodyIsRejectedForBodylessMethods(method: String) {
        expectCompanionDiagnostic {
            try analyze("struct Endpoint { typealias APIResponse = Response; let body: Body }", method: ".\(method)")
        }
    }

    @Test(arguments: [".connect", "chosenMethod"])
    func unsupportedMethodsRequireManualEndpoint(method: String) {
        expectCompanionDiagnostic {
            try analyze("struct Endpoint { typealias APIResponse = Response }", method: method)
        }
    }

    @Test(arguments: ["/missing/{id}", "/../unsafe", "/{id"])
    func invalidRoutesUseCompanionDiagnostic(path: String) {
        expectCompanionDiagnostic { try analyze("struct Endpoint { typealias APIResponse = Response }", path: path) }
    }

    @Test func relativePathKeepsTheSharedJSONRouteContract() throws {
        let result = try analyze("struct Endpoint { typealias APIResponse = Response }", path: "relative/path")
        #expect(result.pathWitness.contains("relative/path"))
    }

    @Test func nonStructDeclarationIsRejected() throws {
        let parsed = Parser.parse(
            source: "@ProtobufAPIDefinition(method: .get, path: \"/\", auth: .anonymous) class Endpoint {}")
        let declaration = try #require(parsed.statements.first?.item.as(ClassDeclSyntax.self))
        let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))
        expectCompanionDiagnostic {
            try EndpointDefinitionExpansion.analyzeEncoded(
                attribute: attribute, declaration: declaration,
                type: IdentifierTypeSyntax(name: declaration.name),
                macroName: "@ProtobufAPIDefinition", policyNames: policyNames)
        }
    }

    private func analyze(
        _ declaration: String, method: String = ".get", path: String = "/", auth: String = ".anonymous"
    ) throws -> EncodedEndpointExpansion {
        let parsed = Parser.parse(
            source: "@ProtobufAPIDefinition(method: \(method), path: \"\(path)\", auth: \(auth))\n" + declaration)
        let structure = try #require(parsed.statements.first?.item.as(StructDeclSyntax.self))
        let attribute = try #require(structure.attributes.first?.as(AttributeSyntax.self))
        return try EndpointDefinitionExpansion.analyzeEncoded(
            attribute: attribute, declaration: structure, type: IdentifierTypeSyntax(name: structure.name),
            macroName: "@ProtobufAPIDefinition", policyNames: policyNames)
    }

    private func expectCompanionDiagnostic(_ operation: () throws -> EncodedEndpointExpansion) {
        do {
            _ = try operation()
            Issue.record("Expected companion endpoint diagnostic")
        } catch let error as DiagnosticsError {
            #expect(!error.diagnostics.isEmpty)
            for diagnostic in error.diagnostics {
                #expect(diagnostic.message.contains("@ProtobufAPIDefinition"))
                #expect(!diagnostic.message.contains("@APIDefinition"))
                #expect(diagnostic.diagMessage.severity == .error)
            }
        } catch { Issue.record(error) }
    }
}
#endif
