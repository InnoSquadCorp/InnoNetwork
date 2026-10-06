#if Macros
import InnoNetwork
import Testing

@APIDefinition(method: .post, path: "/{class}/{id}", auth: .anonymous)
private struct EscapedEndpoint {
    typealias `APIResponse` = String
    let `class`: String
    let `id`: String
    let `body`: String
}

@APIDefinition(method: .get, path: "/{_innoNetworkRequirePathValue}", auth: .anonymous)
private struct HelperCollisionEndpoint {
    typealias APIResponse = String
    let _innoNetworkRequirePathValue: String
}

@Suite("Macro identifier hygiene")
struct MacroIdentifierTests {
    @Test func escapedIdentifiersUseSemanticLookupAndEscapedReferences() {
        let endpoint = EscapedEndpoint(class: "a/b", id: "c d", body: "payload")
        #expect(endpoint.path == "/a%2Fb/c%20d")
        #expect(endpoint.parameters == "payload")
    }

    @Test func generatedHelperDoesNotShadowUserProperty() {
        #expect(HelperCollisionEndpoint(_innoNetworkRequirePathValue: "a/b").path == "/a%2Fb")
    }
}
#endif
