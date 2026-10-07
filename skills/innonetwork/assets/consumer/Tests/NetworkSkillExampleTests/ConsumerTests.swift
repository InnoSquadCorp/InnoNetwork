import Foundation
import InnoNetwork
import InnoNetworkTestSupport
import Testing
import os
@testable import NetworkSkillExample

@Suite(.timeLimit(.minutes(1)))
struct ConsumerTests {
    private let baseURL = URL(string: "https://example.com")!

    private func client(_ session: MockURLSession) -> DefaultNetworkClient {
        DefaultNetworkClient(configuration: .safeDefaults(baseURL: baseURL), session: session)
    }

    private func binary(
        body: EncodedRequestBody? = nil,
        auth: SessionAuthentication = .anonymous,
        options: EncodedRequestOptions = .init()
    ) -> EncodedRequest<Data> {
        .init(method: .post, path: "/binary", auth: auth, body: body,
              options: options, responseDecoder: .init { data, _ in data })
    }

    @Test func macroJSONGetUsesTypedPathAndResponse() async throws {
        let session = MockURLSession()
        let expected = User(id: 7, name: "Ada")
        try session.setMockJSON(expected)
        let client = client(session)
        let user = try await client.request(GetUser(id: 7))
        #expect(user == expected)
        #expect(session.capturedRequest?.url?.path == "/users/7")
        #expect(session.capturedRequest?.httpMethod == "GET")
        #expect(session.capturedRequest?.httpBody == nil)
        await client.shutdown()
    }

    @Test func macroJSONPostEncodesBody() async throws {
        let session = MockURLSession()
        try session.setMockJSON(User(id: 8, name: "Grace"))
        let client = client(session)
        let user = try await client.request(CreateUser(body: .init(name: "Grace")))
        let data = try #require(session.capturedRequest?.httpBody)
        #expect(try JSONDecoder().decode([String: String].self, from: data) == ["name": "Grace"])
        #expect(user.id == 8)
        #expect(session.capturedRequest?.httpMethod == "POST")
        await client.shutdown()
    }

    @Test func namedEncodedEndpointReturnsNonCodableValue() async throws {
        let session = MockURLSession()
        session.setMockResponse(statusCode: 200, data: Data([4, 2]))
        let client = client(session)
        let value = try await client.request(UploadBytes(payload: Data([1, 2, 3])))
        #expect(value == BinaryReceipt(bytes: Data([4, 2])))
        #expect(session.capturedRequest?.httpBody == Data([1, 2, 3]))
        #expect(session.capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        await client.shutdown()
    }

    @Test func retryReusesBytesButNewInvocationEncodesAgain() async throws {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let session = MockURLSession()
        session.setScriptedResponses([.failure(URLError(.timedOut)), .http(statusCode: 200, data: Data([42]))])
        let client = DefaultNetworkClient(
            configuration: .advanced(baseURL: baseURL, resilience: .init(
                retry: ExponentialBackoffRetryPolicy(maxRetries: 1, retryDelay: 0, jitterRatio: 0))),
            session: session
        )
        let request = binary(
            body: .init(contentType: "application/octet-stream") {
                count.withLock { $0 += 1; return Data([UInt8($0)]) }
            }, options: .init(headers: HTTPHeaders(["Idempotency-Key": "fixture-operation"]))
        )
        let value = try await client.request(request)
        #expect(value == Data([42]))
        #expect(count.withLock { $0 } == 1)
        #expect(session.capturedRequestsInOrder.map(\.httpBody) == [Data([1]), Data([1])])
        _ = try await client.request(request)
        #expect(count.withLock { $0 } == 2)
        #expect(session.capturedRequest?.httpBody == Data([2]))
        await client.shutdown()
    }

    @Test func missingAuthenticationRejectsBeforeEncodingOrTransport() async throws {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let session = MockURLSession()
        let client = client(session)
        let request = binary(body: .init(contentType: "application/octet-stream") {
            count.withLock { $0 += 1 }
            return Data([1])
        }, auth: .required)
        await #expect(throws: NetworkError.self) { try await client.request(request) }
        #expect(count.withLock { $0 } == 0)
        #expect(session.capturedRequestsInOrder.isEmpty)
        await client.shutdown()
    }

    @Test func encoderFailureIsConfigurationFailureAndDoesNotSend() async {
        let session = MockURLSession()
        let client = client(session)
        do {
            _ = try await client.request(binary(body: .init(contentType: "application/octet-stream") {
                throw URLError(.timedOut)
            }))
            Issue.record("Expected encoder rejection")
        } catch {
            guard case .configuration(reason: .invalidPayload(.encoding)) = error else {
                Issue.record("Unexpected category: \(error)")
                return
            }
        }
        #expect(session.capturedRequestsInOrder.isEmpty)
        await client.shutdown()
    }

    @Test func nilAndZeroByteBodyHaveDifferentHTTPHeaders() async throws {
        let session = MockURLSession()
        let client = client(session)
        _ = try await client.request(binary())
        #expect(session.capturedRequest?.httpBody == nil)
        #expect(session.capturedRequest?.value(forHTTPHeaderField: "Content-Type") == nil)
        _ = try await client.request(binary(body: .init(contentType: "application/octet-stream") { Data() }))
        #expect(session.capturedRequest?.httpBody == Data())
        #expect(session.capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        await client.shutdown()
    }

    @Test(arguments: [0, 2]) func requestBodyBudgetHasPassingControl(limit: Int) async throws {
        let session = MockURLSession()
        let client = client(session)
        let request = binary(body: .init(contentType: "application/octet-stream", maximumBytes: limit) { Data([1]) })
        if limit == 0 {
            await #expect(throws: NetworkError.self) { try await client.request(request) }
            #expect(session.capturedRequestsInOrder.isEmpty)
        } else {
            _ = try await client.request(request)
            #expect(session.capturedRequestsInOrder.count == 1)
        }
        await client.shutdown()
    }

    @Test(arguments: [1, 16]) func endpointLimitCannotRaiseClientCap(limit: Int64) async {
        let decoded = OSAllocatedUnfairLock(initialState: false)
        let session = MockURLSession()
        session.setMockResponse(statusCode: 200, data: Data(repeating: 1, count: 8))
        let client = DefaultNetworkClient(configuration: .advanced(
            baseURL: baseURL, resilience: .init(bodyBuffering: .streaming(maxBytes: 4))), session: session)
        let request = EncodedRequest<Data>(method: .get, path: "/bounded", auth: .anonymous,
            options: .init(maximumResponseBytes: limit), responseDecoder: .init { data, _ in
                decoded.withLock { $0 = true }
                return data
            })
        await #expect(throws: NetworkError.self) { try await client.request(request) }
        #expect(!decoded.withLock { $0 })
        #expect(session.capturedRequestsInOrder.count == 1)
        await client.shutdown()
    }

    @Test(arguments: [200, 204, 205]) func noContentRequiresMatchingStatusAndEmptyBody(status: Int) async throws {
        let session = MockURLSession()
        let client = client(session)
        let request = EncodedRequest<EmptyResponse>(method: .get, path: "/empty", auth: .anonymous,
                                                    responseDecoder: .noContent())
        session.setMockResponse(statusCode: status)
        if status == 200 {
            await #expect(throws: NetworkError.self) { try await client.request(request) }
        } else {
            _ = try await client.request(request)
        }
        session.setMockResponse(statusCode: status, data: Data([1]))
        await #expect(throws: NetworkError.self) { try await client.request(request) }
        await client.shutdown()
    }

    @Test func operationSupportsJSONAndEncodedEndpoints() async throws {
        let session = MockURLSession()
        let expected = User(id: 7, name: "Ada")
        try session.setMockJSON(expected)
        let client = client(session)
        let operations = OperationNetworkClient(client: client)
        let user = try await operations.startUser(id: 7).value()
        #expect(user == expected)
        session.setMockResponse(statusCode: 200, data: Data([9]))
        let receipt = try await operations.start(UploadBytes(payload: Data([1]))).value()
        #expect(receipt.bytes == Data([9]))
        await client.shutdown()
    }

    @Test func expiredOperationDoesNotEncodeOrSend() async {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let session = MockURLSession()
        let client = client(session)
        let request = binary(body: .init(contentType: "application/octet-stream") {
            count.withLock { $0 += 1 }
            return Data([1])
        })
        let operation = OperationNetworkClient(client: client).start(request, deadline: .init(after: .zero))
        do {
            _ = try await operation.value()
            Issue.record("Expected expired deadline")
        } catch {
            #expect(error.kind == .timeout)
            #expect(error.deadlineStage == .requestPreparation)
        }
        #expect(count.withLock { $0 } == 0)
        #expect(session.capturedRequestsInOrder.isEmpty)
        await client.shutdown()
    }

    @Test func codecCancellationAndClosedClientRemainCancelled() async {
        let session = MockURLSession()
        let client = client(session)
        do {
            _ = try await client.request(binary(body: .init(contentType: "application/octet-stream") {
                throw CancellationError()
            }))
            Issue.record("Expected codec cancellation")
        } catch {
            guard case .cancelled = error else { Issue.record("Unexpected error: \(error)"); return }
        }
        await client.shutdown()
        do {
            _ = try await client.request(GetUser(id: 7))
            Issue.record("Expected closed client rejection")
        } catch {
            guard case .cancelled = error else { Issue.record("Unexpected error: \(error)"); return }
        }
        #expect(session.capturedRequestsInOrder.isEmpty)
    }
}
