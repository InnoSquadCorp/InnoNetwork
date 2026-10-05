import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork

@Suite("Named encoded endpoint bridge")
struct EncodedAPIDefinitionTests {
    struct Definition: EncodedAPIDefinition {
        typealias APIResponse = Data
        let count: OSAllocatedUnfairLock<Int>
        var method: HTTPMethod { .get }
        var path: String { "/binary" }
        var sessionAuthentication: SessionAuthentication { .anonymous }
        var mismatch = false
        var fails = false
        func makeEncodedRequest() throws(NetworkError) -> EncodedRequest<Data> {
            count.withLock { $0 += 1 }
            if fails { throw .configuration(reason: .invalidPayload(.invalidLimit)) }
            return .init(
                method: method, path: mismatch ? "/other" : path, auth: sessionAuthentication,
                responseDecoder: .init { data, _ in data })
        }
    }

    struct BinaryOnlyClient: EncodedRequestClient {
        let tags: OSAllocatedUnfairLock<[CancellationTag?]>
        func request<Output: Sendable>(
            _ request: EncodedRequest<Output>, tag: CancellationTag?
        ) async throws(NetworkError) -> Output {
            tags.withLock { $0.append(tag) }
            throw .cancelled
        }
    }

    struct UnsupportedCredentialDefinition: EncodedAPIDefinition, RequestSecurityProviding {
        let base: Definition
        let requestSecurity: RequestSecurity
        var method: HTTPMethod { base.method }
        var path: String { base.path }
        var sessionAuthentication: SessionAuthentication { base.sessionAuthentication }
        func makeEncodedRequest() throws(NetworkError) -> EncodedRequest<Data> {
            try base.makeEncodedRequest()
        }
    }

    struct UnusedCredentialProvider: RequestCredentialProvider {
        func select(
            alternatives: [[RequestSecurity.Scheme]], origin: URL
        ) async throws -> RequestSecurity.Selection {
            Issue.record("Unsupported encoded credentials must not select a provider")
            throw RequestSecurityFailure.unsupportedExecution
        }
        func credential(
            for scheme: RequestSecurity.Scheme, selection: RequestSecurity.Selection, origin: URL
        ) async throws -> RequestSecurity.Credential {
            Issue.record("Unsupported encoded credentials must not acquire credentials")
            throw RequestSecurityFailure.unsupportedExecution
        }
    }

    @Test(arguments: [false, true])
    func unsupportedNamedCredentialsFailBeforeFactoryAndTransport(operationRoute: Bool) async throws {
        let url = try #require(URL(string: "https://example.com"))
        let session = MockURLSession()
        session.setMockResponse(statusCode: 200, data: Data([42]))
        let client = DefaultNetworkClient(configuration: .safeDefaults(baseURL: url), session: session)
        let count = OSAllocatedUnfairLock(initialState: 0)
        let endpoint = UnsupportedCredentialDefinition(
            base: Definition(count: count),
            requestSecurity: try RequestSecurity(
                origin: url, alternatives: [[.bearer(id: "named")]], provider: UnusedCredentialProvider()))
        if operationRoute {
            do {
                _ = try await OperationNetworkClient(client: client).start(endpoint).value()
                Issue.record("Unsupported named credentials unexpectedly succeeded")
            } catch let failure {
                #expect(failure.kind == .configuration)
                #expect(failure.recovery == .doNotRetry)
                #expect(failure.code == NetworkFailure(
                    migratingV5: RequestSecurityFailure.unsupportedExecution.networkError).code)
            }
        } else {
            do {
                _ = try await client.request(endpoint)
                Issue.record("Unsupported named credentials unexpectedly succeeded")
            } catch {
                guard case .underlying(let failure, _) = error else {
                    Issue.record("Unexpected credential failure: \(error)")
                    return
                }
                #expect(failure.domain == "InnoNetwork.RequestSecurity")
                #expect(failure.code == RequestSecurityFailure.unsupportedExecution.rawValue)
            }
        }
        #expect(count.withLock { $0 } == 0)
        #expect(session.capturedRequestsInOrder.isEmpty)
    }

    @Test func directAndOperationUseOneFactoryEach() async throws {
        let session = MockURLSession()
        session.setMockResponse(statusCode: 200, data: Data([42]))
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://example.com")!), session: session)
        let count = OSAllocatedUnfairLock(initialState: 0)
        let endpoint = Definition(count: count)
        #expect(try await client.request(endpoint) == Data([42]))
        #expect(try await OperationNetworkClient(client: client).start(endpoint).value() == Data([42]))
        #expect(count.withLock { $0 } == 2)
    }

    @Test func mismatchAndFactoryFailureDoNotSend() async throws {
        let session = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://example.com")!), session: session)
        for endpoint in [
            Definition(count: .init(initialState: 0), mismatch: true),
            Definition(count: .init(initialState: 0), fails: true),
        ] {
            await #expect(throws: NetworkError.self) { try await client.request(endpoint) }
            await #expect(throws: NetworkFailure.self) {
                try await OperationNetworkClient(client: client).start(endpoint).value()
            }
            #expect(endpoint.count.withLock { $0 } == 2)
        }
        #expect(session.capturedRequestsInOrder.isEmpty)
    }

    @Test func expiredOperationDoesNotCallFactory() async {
        let tags = OSAllocatedUnfairLock(initialState: [CancellationTag?]())
        let client = BinaryOnlyClient(tags: tags)
        let endpoint = Definition(count: .init(initialState: 0))
        await #expect(throws: NetworkFailure.self) {
            try await OperationNetworkClient(client: client).start(endpoint, deadline: .init(after: .zero)).value()
        }
        #expect(endpoint.count.withLock { $0 } == 0)
        #expect(tags.withLock { $0.isEmpty })
    }

    @Test func forwardsTagToBinaryOnlyClient() async {
        let tags = OSAllocatedUnfairLock(initialState: [CancellationTag?]())
        let endpoint = Definition(count: .init(initialState: 0))
        await #expect(throws: NetworkError.self) {
            try await BinaryOnlyClient(tags: tags).request(endpoint, tag: "named-binary")
        }
        #expect(tags.withLock { $0 } == ["named-binary"])
        #expect(endpoint.count.withLock { $0 } == 1)
    }

    @Test func cancelledCallerDoesNotPrepare() async {
        let endpoint = Definition(count: .init(initialState: 0))
        let client = BinaryOnlyClient(tags: .init(initialState: []))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: NetworkError.self) { try await client.request(endpoint) }
        }
        await task.value
        #expect(endpoint.count.withLock { $0 } == 0)
    }

    @Test func queryAppendingPreservesOptionsAndSanitizesFailures() throws {
        struct Query: Encodable, Sendable { let q: [String] }
        struct Broken: Encodable, Sendable {
            struct Secret: Error { let token = "not-for-diagnostics" }
            func encode(to encoder: any Encoder) throws { throw Secret() }
        }
        let original = EncodedRequestOptions(queryItems: [.init(name: "q", value: "first")])
        let result = try original.addingQuery(
            Query(q: ["second", "third"]), encoder: .init(arrayEncodingStrategy: .repeated))
        #expect(result.queryItems.map(\.value) == ["first", "second", "third"])
        #expect(original.queryItems.map(\.value) == ["first"])
        do {
            _ = try original.addingQuery(Broken())
            Issue.record("Broken query unexpectedly encoded")
        } catch NetworkError.configuration(reason: .invalidPayload(.encoding)) {
            // Only a payload-free category crosses the public boundary.
        }
        struct Empty: Encodable, Sendable {}
        #expect(try original.addingQuery(Empty()).queryItems == original.queryItems)
    }
}
