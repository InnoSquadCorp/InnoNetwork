import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork

@Suite("Stable encoded requests")
struct EncodedRequestTests {
    @Test("No-content decoder accepts empty 204 and 205 responses", arguments: [204, 205])
    func noContentAcceptsDefaultStatuses(statusCode: Int) async throws {
        let session = MockURLSession()
        session.setMockResponse(statusCode: statusCode)
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://example.com")!), session: session)
        let value = EncodedRequest<EmptyResponse>(
            method: .get, path: "/empty", auth: .anonymous, responseDecoder: .noContent())

        _ = try await client.request(value)

        #expect(session.capturedRequestsInOrder.count == 1)
    }

    @Test("No-content decoder rejects bytes even for 204 and 205", arguments: [204, 205])
    func noContentRejectsNonemptyBodies(statusCode: Int) async throws {
        try await expectNoContentFailure(statusCode: statusCode, data: Data([0]))
    }

    @Test("No-content decoder rejects an empty 200 by default")
    func noContentRejectsDefault200() async throws {
        try await expectNoContentFailure(statusCode: 200)
    }

    @Test("No-content decoder accepts explicitly configured empty responses", arguments: [200, 202, 418])
    func noContentAcceptsCustomStatuses(statusCode: Int) async throws {
        let session = MockURLSession()
        session.setMockResponse(statusCode: statusCode)
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://example.com")!), session: session)
        let value = EncodedRequest<EmptyResponse>(
            method: .get, path: "/empty", auth: .anonymous,
            options: .init(acceptableStatusCodes: [statusCode]),
            responseDecoder: .noContent(statusCodes: [statusCode]))

        _ = try await client.request(value)

        #expect(session.capturedRequestsInOrder.count == 1)
    }

    @Test("Custom no-content statuses still require an empty body")
    func noContentCustomStatusRejectsNonemptyBody() async throws {
        try await expectNoContentFailure(statusCode: 200, data: Data([0]), decoder: .noContent(statusCodes: [200]))
    }

    @Test("Custom no-content statuses replace the defaults", arguments: [204, 205])
    func noContentCustomStatusesReplaceDefaults(statusCode: Int) async throws {
        try await expectNoContentFailure(statusCode: statusCode, decoder: .noContent(statusCodes: [200]))
    }

    @Test("An empty no-content status set rejects every response", arguments: [200, 204, 205])
    func noContentRejectsEmptyStatusSet(statusCode: Int) async throws {
        try await expectNoContentFailure(statusCode: statusCode, decoder: .noContent(statusCodes: []))
    }

    private func expectNoContentFailure(
        statusCode: Int, data: Data = Data(), decoder: AnyResponseDecoder<EmptyResponse> = .noContent()
    ) async throws {
        let session = MockURLSession()
        session.setMockResponse(statusCode: statusCode, data: data)
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://example.com")!), session: session)
        let value = EncodedRequest<EmptyResponse>(
            method: .get, path: "/empty", auth: .anonymous, responseDecoder: decoder)

        do {
            _ = try await client.request(value)
            Issue.record("Expected no-content decoding failure for status \(statusCode)")
        } catch {
            guard case .decoding(let stage, let underlying, let response) = error else {
                Issue.record("Wrong no-content error: \(error)")
                return
            }
            #expect(stage == .responseBody)
            #expect(underlying.domain == EncodedPayloadFailure.errorDomain)
            #expect(underlying.code == EncodedPayloadFailure.unexpectedContent.rawValue)
            #expect(response.statusCode == statusCode)
            #expect(response.data == data)
        }
        #expect(session.capturedRequestsInOrder.count == 1)
    }

    @Test("Response codec cancellation is not decoding failure or a retryable transport error")
    func responseCodecCancellation() async throws {
        let errors: [any Error] = [CancellationError(), URLError(.cancelled), NetworkError.cancelled]
        for error in errors {
            let session = MockURLSession()
            session.setMockResponse(statusCode: 200, data: Data([42]))
            let client = DefaultNetworkClient(
                configuration: .advanced(
                    baseURL: URL(string: "https://example.com")!,
                    resilience: .init(retry: ExponentialBackoffRetryPolicy(maxRetries: 1, retryDelay: 0))),
                session: session)
            let value = EncodedRequest<Data>(
                method: .get, path: "/binary", auth: .anonymous,
                responseDecoder: .init { _, _ in throw error })
            do {
                _ = try await client.request(value)
                Issue.record("Expected cancellation")
            } catch {
                guard case .cancelled = error else {
                    Issue.record("Cancellation changed to \(error)")
                    continue
                }
            }
            #expect(session.capturedRequestsInOrder.count == 1)
        }
    }

    @Test("Codec cancellation keeps the typed cancellation contract before transport")
    func codecCancellation() async throws {
        let errors: [any Error] = [CancellationError(), URLError(.cancelled), NetworkError.cancelled]
        for error in errors {
            let session = MockURLSession()
            let client = DefaultNetworkClient(
                configuration: .safeDefaults(baseURL: URL(string: "https://example.com")!), session: session)
            let value = request(body: .init(contentType: "application/octet-stream") { throw error })
            do {
                _ = try await client.request(value)
                Issue.record("Expected cancellation")
            } catch {
                guard case .cancelled = error else {
                    Issue.record("Cancellation changed to \(error)")
                    continue
                }
            }
            #expect(session.capturedRequestsInOrder.isEmpty)
        }
    }
    @Test func forcedRepreparationDoesNotReencodeFailure() throws {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let executable = EncodedRequestExecutable(
            request(
                body: .init(contentType: "application/octet-stream") {
                    count.withLock { $0 += 1 }
                    throw URLError(.timedOut)
                }))
        for _ in 0..<2 {
            #expect(throws: NetworkError.self) { try executable.makePayload() }
        }
        #expect(count.withLock { $0 } == 1)
    }

    @Test func groupedCancellationStopsBeforeTransportWithoutAffectingOtherRequests() async throws {
        let (entered, continuation) = AsyncStream<Void>.makeStream()
        struct Hold: RequestInterceptor {
            let entered: AsyncStream<Void>.Continuation
            func adapt(_ request: URLRequest) async throws -> URLRequest {
                entered.yield(())
                try await Task.sleep(for: .seconds(60))
                return request
            }
        }
        let session = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://example.com")!), session: session)
        let held = request(options: .init(requestInterceptors: [Hold(entered: continuation)]))
        let tag: CancellationTag = "binary-held"
        let task = Task { try await client.request(held, tag: tag) }
        var iterator = entered.makeAsyncIterator()
        await iterator.next()
        await client.cancelAll(matching: "unrelated")
        _ = try await client.request(request(), tag: "control")
        await client.cancelAll(matching: tag)
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            guard case NetworkError.cancelled = error else {
                Issue.record("Wrong cancellation: \(error)")
                return
            }
        }
        #expect(session.capturedRequestsInOrder.count == 1)
        continuation.finish()
    }

    @Test func optionsUseTheExistingInterceptorAndSigningPipeline() async throws {
        struct Adapt: RequestInterceptor {
            func adapt(_ request: URLRequest) async throws -> URLRequest {
                var result = request
                result.setValue("adapted", forHTTPHeaderField: "X-Adapted")
                return result
            }
        }
        struct Sign: RequestSigner {
            func signatureHeaders(for request: URLRequest, body: RequestBody) async throws -> HTTPHeaders {
                #expect(request.value(forHTTPHeaderField: "X-Adapted") == "adapted")
                guard case .data(let bytes) = body else {
                    Issue.record("Missing signing bytes")
                    return .init()
                }
                #expect(bytes == Data([1, 2]))
                return HTTPHeaders(["X-Signature": bytes.base64EncodedString()])
            }
        }
        struct Observe: ResponseInterceptor {
            func adapt(_ response: Response, request: URLRequest) async throws -> Response {
                #expect(response.statusCode == 418)
                #expect(request.value(forHTTPHeaderField: "X-Signature") == "AQI=")
                return response
            }
        }
        let session = MockURLSession()
        session.setMockResponse(statusCode: 418, data: Data([3]))
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://example.com")!), session: session)
        let value = request(
            body: .init(contentType: "application/octet-stream") { Data([1, 2]) },
            options: .init(
                requestInterceptors: [Adapt()], requestSigners: [Sign()], responseInterceptors: [Observe()],
                acceptableStatusCodes: [418], allowsExpensiveNetworkAccess: false, allowsConstrainedNetworkAccess: false
            ))
        #expect(try await client.request(value) == Data([3]))
        let sent = try #require(session.capturedRequest)
        #expect(!sent.allowsExpensiveNetworkAccess && !sent.allowsConstrainedNetworkAccess)
        #expect(sent.value(forHTTPHeaderField: "X-Signature") == "AQI=")
    }

    private func request(
        body: EncodedRequestBody? = nil, options: EncodedRequestOptions = .init(),
        method: HTTPMethod = .post, path: String = "/binary", auth: SessionAuthentication = .anonymous
    ) -> EncodedRequest<Data> {
        .init(
            method: method, path: path, auth: auth, body: body, options: options,
            responseDecoder: .init { data, _ in data })
    }

    @Test func preparesBodyOncePerInvocationAcrossRetries() async throws {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let measurements = OSAllocatedUnfairLock(initialState: [EncodedCodecMeasurement]())
        let session = MockURLSession()
        session.setScriptedResponses([.failure(URLError(.timedOut)), .http(statusCode: 200, data: Data([42]))])
        let retry = ExponentialBackoffRetryPolicy(maxRetries: 1, retryDelay: 0, jitterRatio: 0)
        let client = DefaultNetworkClient(
            configuration: .advanced(
                baseURL: URL(string: "https://example.com")!, resilience: .init(retry: retry)), session: session)
        let value = request(
            body: .init(contentType: "application/octet-stream") {
                count.withLock {
                    $0 += 1
                    return Data([UInt8($0)])
                }
            },
            options: .init(
                headers: HTTPHeaders(["Idempotency-Key": "stable"]),
                codecObserver: { sample in
                    measurements.withLock { $0.append(sample) }
                }))
        #expect(try await client.request(value) == Data([42]))
        #expect(count.withLock { $0 } == 1)
        #expect(session.capturedRequestsInOrder.map(\.httpBody) == [Data([1]), Data([1])])
        session.setMockResponse(statusCode: 200)
        _ = try await client.request(value)
        #expect(count.withLock { $0 } == 2)
        #expect(session.capturedRequest?.httpBody == Data([2]))
        let samples = measurements.withLock { $0 }
        #expect(samples.map(\.stage) == [.encoding, .decoding, .encoding, .decoding])
        #expect(samples.allSatisfy { $0.succeeded && $0.duration >= .zero })
        #expect(samples.map(\.byteCount) == [1, 1, 1, 0])
        #expect(session.capturedRequest?.url?.absoluteString == "https://example.com/binary")
    }

    @Test("401 refresh reuses encoded bytes and decodes only the final response")
    func preparesBodyOnceAcrossAuthenticationRefresh() async throws {
        let encodingCount = OSAllocatedUnfairLock(initialState: 0)
        let decodingCount = OSAllocatedUnfairLock(initialState: 0)
        let refreshCount = OSAllocatedUnfairLock(initialState: 0)
        let measurements = OSAllocatedUnfairLock(initialState: [EncodedCodecMeasurement]())
        let session = MockURLSession()
        session.setScriptedResponses([
            .http(statusCode: 401, data: Data([0])),
            .http(statusCode: 200, data: Data([42])),
        ])
        let policy = RefreshTokenPolicy(
            currentToken: { "old-token" },
            refreshToken: {
                refreshCount.withLock { $0 += 1 }
                return "new-token"
            })
        let client = DefaultNetworkClient(
            configuration: .advanced(
                baseURL: URL(string: "https://example.com")!, auth: .init(refreshToken: policy)),
            session: session)
        let value = EncodedRequest<Data>(
            method: .post, path: "/binary", auth: .required,
            body: .init(contentType: "application/octet-stream") {
                encodingCount.withLock {
                    $0 += 1
                    return Data([UInt8($0)])
                }
            },
            options: .init(codecObserver: { sample in measurements.withLock { $0.append(sample) } }),
            responseDecoder: .init { data, response in
                decodingCount.withLock { $0 += 1 }
                #expect(response.statusCode == 200)
                #expect(data == Data([42]))
                return data
            })

        #expect(try await client.request(value) == Data([42]))

        #expect(encodingCount.withLock { $0 } == 1)
        #expect(refreshCount.withLock { $0 } == 1)
        #expect(decodingCount.withLock { $0 } == 1)
        let sent = session.capturedRequestsInOrder
        #expect(sent.count == 2)
        #expect(sent.map(\.httpBody) == [Data([1]), Data([1])])
        #expect(sent.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer old-token", "Bearer new-token"])
        #expect(sent.allSatisfy { $0.httpMethod == "POST" && $0.url?.path == "/binary" })
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream" })
        let samples = measurements.withLock { $0 }
        #expect(samples.map(\.stage) == [.encoding, .decoding])
        #expect(samples.map(\.byteCount) == [1, 1])
        #expect(samples.allSatisfy { $0.succeeded && $0.duration >= .zero })
    }

    @Test func rejectsInvalidInputBeforeEncoding() async throws {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let session = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://example.com")!), session: session)
        let body = EncodedRequestBody(contentType: "application/octet-stream") {
            count.withLock { $0 += 1 }
            return Data()
        }
        for value in [
            request(body: body, method: .get), request(body: body, path: "/bad%Q0"),
            request(body: body, auth: .required),
        ] {
            await #expect(throws: NetworkError.self) { try await client.request(value) }
        }
        #expect(count.withLock { $0 } == 0)
        #expect(session.capturedRequestsInOrder.isEmpty)
    }

    @Test func localCodecErrorsDoNotBecomeTransportErrors() async throws {
        let session = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://example.com")!), session: session)
        let value = request(body: .init(contentType: "application/octet-stream") { throw URLError(.timedOut) })
        do {
            _ = try await client.request(value)
            Issue.record("Expected encoding failure")
        } catch {
            guard case .configuration(reason: .invalidPayload(.encoding)) = error else {
                Issue.record("Wrong category: \(error)")
                return
            }
            #expect(!error.isRetriableHint)
        }
        #expect(session.capturedRequestsInOrder.isEmpty)
    }

    @Test func forwardsEnvelopeAndDistinguishesEmptyBody() async throws {
        let session = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://example.com")!), session: session)
        let options = EncodedRequestOptions(
            queryItems: [.init(name: "a", value: "a&b")], timeout: 7,
            cachePolicy: .reloadIgnoringLocalCacheData, allowsCellularAccess: false)
        _ = try await client.request(request(options: options))
        #expect(session.capturedRequest?.httpBody == nil)
        #expect(session.capturedRequest?.value(forHTTPHeaderField: "Content-Type") == nil)
        _ = try await client.request(
            request(body: .init(contentType: "application/octet-stream") { Data() }, options: options))
        let sent = try #require(session.capturedRequest)
        #expect(sent.httpBody == Data())
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(sent.timeoutInterval == 7)
        #expect(!sent.allowsCellularAccess)
        #expect(URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems == options.queryItems)
    }

    @Test(arguments: [0, 8]) func requestBudget(limit: Int) async throws {
        let session = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://example.com")!), session: session)
        let value = request(body: .init(contentType: "application/octet-stream", maximumBytes: limit) { Data([1]) })
        if limit == 0 {
            do {
                _ = try await client.request(value)
                Issue.record("Expected limit")
            } catch {
                guard case .configuration(reason: .invalidPayload(.requestBodyLimit)) = error else {
                    Issue.record("Wrong limit error")
                    return
                }
            }
            #expect(session.capturedRequestsInOrder.isEmpty)
        } else {
            _ = try await client.request(value)
            #expect(session.capturedRequestsInOrder.count == 1)
        }
    }

    @Test(arguments: [1, 16]) func responseLimitCannotRaiseClientCap(limit: Int64) async throws {
        let session = MockURLSession()
        session.setMockResponse(statusCode: 200, data: Data(repeating: 1, count: 8))
        let client = DefaultNetworkClient(
            configuration: .advanced(
                baseURL: URL(string: "https://example.com")!,
                resilience: .init(bodyBuffering: .streaming(maxBytes: 4))), session: session)
        await #expect(throws: NetworkError.self) {
            try await client.request(request(options: .init(maximumResponseBytes: limit)))
        }
    }

    @Test func binaryOnlyClientSupportsOperationsAndTypedThrows() async throws {
        struct BinaryOnly: EncodedRequestClient {
            func request<Output: Sendable>(_ request: EncodedRequest<Output>, tag: CancellationTag?)
                async throws(NetworkError) -> Output
            {
                #expect(tag != nil)
                let response = Response(
                    statusCode: 204, data: Data(),
                    response: HTTPURLResponse(
                        url: URL(string: "https://example.com")!, statusCode: 204, httpVersion: nil, headerFields: nil)!
                )
                do { return try request.responseDecoder.decode(data: Data(), response: response) } catch {
                    throw .cancelled
                }
            }
        }
        let operation = OperationNetworkClient(client: BinaryOnly()).start(request())
        #expect(try await operation.value() == Data())
        var events: [NetworkOperationEvent] = []
        for await event in operation.events { events.append(event) }
        #expect(events == [.started(id: operation.id), .succeeded(id: operation.id)])
    }

    @Test func binaryOperationCancellationWaitsForEntry() async throws {
        let (entered, continuation) = AsyncStream<CancellationTag>.makeStream()
        struct WaitingClient: EncodedRequestClient {
            let entered: AsyncStream<CancellationTag>.Continuation
            func request<Output: Sendable>(_ request: EncodedRequest<Output>, tag: CancellationTag?)
                async throws(NetworkError) -> Output
            {
                if let tag { entered.yield(tag) }
                do { try await Task.sleep(for: .seconds(60)) } catch { throw .cancelled }
                throw .configuration(reason: .invalidPayload(.unexpectedContent))
            }
        }
        let operation = OperationNetworkClient(client: WaitingClient(entered: continuation)).start(request())
        var iterator = entered.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        operation.cancel()
        do {
            _ = try await operation.value()
            Issue.record("Expected cancellation")
        } catch { #expect(error.kind == .cancelled) }
        var terminalCount = 0
        for await event in operation.events {
            if case .failed = event { terminalCount += 1 }
        }
        #expect(terminalCount == 1)
        continuation.finish()
    }

    @Test func expiredBinaryDeadlineDoesNotEncodeOrDispatch() async throws {
        let session = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://example.com")!), session: session)
        let count = OSAllocatedUnfairLock(initialState: 0)
        let value = request(
            body: .init(contentType: "application/octet-stream") {
                count.withLock { $0 += 1 }
                return Data()
            })
        let operation = OperationNetworkClient(client: client).start(value, deadline: .init(after: .zero))
        do {
            _ = try await operation.value()
            Issue.record("Expected timeout")
        } catch {
            #expect(error.kind == .timeout)
            #expect(error.recovery == .doNotRetry)
        }
        #expect(count.withLock { $0 } == 0)
        #expect(session.capturedRequestsInOrder.isEmpty)
    }

    @Test func codecFailureMeasurementContainsNoPayload() async throws {
        let session = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://example.com")!), session: session)
        let measurements = OSAllocatedUnfairLock(initialState: [EncodedCodecMeasurement]())
        let value = request(
            body: .init(contentType: "application/octet-stream") { throw URLError(.timedOut) },
            options: .init(codecObserver: { sample in measurements.withLock { $0.append(sample) } }))
        await #expect(throws: NetworkError.self) { try await client.request(value) }
        let samples = measurements.withLock { $0 }
        #expect(samples.count == 1)
        #expect(samples.first?.stage == .encoding)
        #expect(samples.first?.byteCount == nil)
        #expect(samples.first?.succeeded == false)
    }
}
