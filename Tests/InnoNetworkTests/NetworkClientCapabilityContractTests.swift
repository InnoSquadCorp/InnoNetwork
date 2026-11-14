import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

private struct CapabilityRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = String

    var sessionAuthentication: SessionAuthentication { .anonymous }
    var method: HTTPMethod { .get }
    var path: String { "/contract/request" }
}

private struct CapabilityUpload: MultipartAPIDefinition {
    typealias APIResponse = String

    var sessionAuthentication: SessionAuthentication { .anonymous }
    var method: HTTPMethod { .post }
    var path: String { "/contract/upload" }
    var multipartFormData: MultipartFormData {
        var formData = MultipartFormData(boundary: "capability-contract")
        formData.append("value", name: "field")
        return formData
    }
}

private actor RequestOnlyClient: NetworkClient {
    private var invocationCount = 0
    private var lastTag: CancellationTag?

    func request<Request: APIDefinition>(
        _ request: Request,
        tag: CancellationTag?
    ) async throws(NetworkError) -> Request.APIResponse {
        invocationCount += 1
        lastTag = tag
        throw .cancelled
    }

    func observation() -> (count: Int, tag: CancellationTag?) {
        (invocationCount, lastTag)
    }
}

private actor UploadOnlyClient: UploadNetworkClient {
    private var invocationCount = 0
    private var lastTag: CancellationTag?

    func upload<Request: MultipartAPIDefinition>(
        _ request: Request,
        tag: CancellationTag?
    ) async throws(NetworkError) -> Request.APIResponse {
        invocationCount += 1
        lastTag = tag
        throw .cancelled
    }

    func observation() -> (count: Int, tag: CancellationTag?) {
        (invocationCount, lastTag)
    }
}

@Suite("Network client capability contracts")
struct NetworkClientCapabilityContractTests {
    @Test("Request-only conformers implement no upload requirements")
    func requestOnlyCapabilityForwardsUntaggedCallsToTheTaggedPrimitive() async {
        let concreteClient = RequestOnlyClient()
        let client: any NetworkClient = concreteClient

        await #expect(throws: NetworkError.self) {
            _ = try await client.request(CapabilityRequest())
        }

        let observation = await concreteClient.observation()
        #expect(observation.count == 1)
        #expect(observation.tag == nil)
    }

    @Test("Upload-only conformers implement no request requirements")
    func uploadOnlyCapabilityForwardsUntaggedCallsToTheTaggedPrimitive() async {
        let concreteClient = UploadOnlyClient()
        let client: any UploadNetworkClient = concreteClient

        await #expect(throws: NetworkError.self) {
            _ = try await client.upload(CapabilityUpload())
        }

        let observation = await concreteClient.observation()
        #expect(observation.count == 1)
        #expect(observation.tag == nil)
    }

    @Test("Capability primitives preserve explicit cancellation tags")
    func taggedPrimitivesPreserveTags() async {
        let requestClient = RequestOnlyClient()
        let uploadClient = UploadOnlyClient()
        let tag = CancellationTag("capability-contract")

        await #expect(throws: NetworkError.self) {
            _ = try await requestClient.request(CapabilityRequest(), tag: tag)
        }
        await #expect(throws: NetworkError.self) {
            _ = try await uploadClient.upload(CapabilityUpload(), tag: tag)
        }

        #expect(await requestClient.observation().tag == tag)
        #expect(await uploadClient.observation().tag == tag)
    }

    @Test("Every conformer can start an operation handle for its own capability")
    func conformersStartOperationsThroughTheTaggedPrimitive() async {
        let requestClient = RequestOnlyClient()
        let uploadClient = UploadOnlyClient()

        let request = requestClient.start(CapabilityRequest())
        let upload = uploadClient.startUpload(CapabilityUpload())

        await #expect(throws: NetworkError.self) { _ = try await request.value() }
        await #expect(throws: NetworkError.self) { _ = try await upload.value() }

        // The handle's identifier is the cancellation tag given to the client.
        #expect(await requestClient.observation().tag == CancellationTag(request.id.uuidString))
        #expect(await uploadClient.observation().tag == CancellationTag(upload.id.uuidString))
        #expect(await requestClient.observation().count == 1)
        #expect(await uploadClient.observation().count == 1)
        #expect(await upload.failureSummary()?.category == .cancellation)

        var uploadEvents: [NetworkOperationEvent] = []
        for await event in upload.events { uploadEvents.append(event) }
        #expect(uploadEvents.first == .started(id: upload.id))
        #expect(uploadEvents.count == 2)
    }

    @Test("Default and stub clients expose both independent capabilities")
    func concreteClientsExposeBothCapabilities() {
        func acceptsBoth(_ client: any NetworkClient & UploadNetworkClient) {}

        acceptsBoth(
            DefaultNetworkClient(
                configuration: makeTestNetworkConfiguration(baseURL: "https://example.invalid"),
                session: MockURLSession()
            )
        )
        acceptsBoth(StubNetworkClient())
    }

    @Test("Stub upload fallback is independently injectable")
    func stubPreservesUploadFallbackTags() async {
        let fallback = UploadOnlyClient()
        let client = StubNetworkClient(uploadFallback: fallback)
        let tag = CancellationTag("stub-upload")

        await #expect(throws: NetworkError.self) {
            _ = try await client.upload(CapabilityUpload(), tag: tag)
        }

        #expect(await fallback.observation().tag == tag)
    }
}
