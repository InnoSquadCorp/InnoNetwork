import Foundation
import Testing

@testable import InnoNetwork

@Suite("Response Body Limit Tests")
struct ResponseBodyLimitTests {

    private struct DataEcho: APIDefinition {
        var sessionAuthentication: SessionAuthentication { .anonymous }
        typealias Parameter = EmptyParameter
        typealias APIResponse = Data
        var method: HTTPMethod { .get }
        var path: String { "/echo" }
        var headers: HTTPHeaders { [] }

        var transport: TransportPolicy<Data> {
            .custom(encoding: .json(defaultRequestEncoder)) { data, _ in data }
        }
    }

    private struct ReplacingResponseBody: ResponseInterceptor {
        let data: Data

        func adapt(_ urlResponse: Response, request: URLRequest) async throws -> Response {
            guard let response = urlResponse.response else { return urlResponse }
            return Response(
                statusCode: urlResponse.statusCode,
                data: data,
                request: urlResponse.request,
                response: response
            )
        }
    }

    private struct ReplacingDecodableData: DecodingInterceptor {
        let data: Data

        func willDecode(data: Data, response: Response) async throws -> Data {
            self.data
        }
    }

    private actor ResponseEventCounter: NetworkEventObserving {
        private(set) var responseReceivedCount = 0
        private var didReceiveRequestFailure = false
        private var requestFailureWaiters: [CheckedContinuation<Void, Never>] = []

        func handle(_ event: NetworkEvent) async {
            switch event {
            case .responseReceived:
                responseReceivedCount += 1
            case .requestFailed:
                didReceiveRequestFailure = true
                let waiters = requestFailureWaiters
                requestFailureWaiters.removeAll(keepingCapacity: false)
                for waiter in waiters {
                    waiter.resume()
                }
            default:
                break
            }
        }

        func waitForRequestFailure() async {
            guard !didReceiveRequestFailure else { return }
            await withCheckedContinuation { continuation in
                requestFailureWaiters.append(continuation)
            }
        }
    }

    private actor ExecutionPolicyResponseCounter {
        private(set) var responseCount = 0

        func recordResponse() {
            responseCount += 1
        }
    }

    private struct ResponseObservingExecutionPolicy: RequestExecutionPolicy {
        let counter: ExecutionPolicyResponseCounter

        func execute(
            input: RequestExecutionInput,
            context: RequestExecutionContext,
            next: RequestExecutionNext
        ) async throws -> Response {
            let response = try await next.execute()
            await counter.recordResponse()
            return response
        }
    }

    @Test("Body under the limit passes through unchanged")
    func underLimitPasses() async throws {
        let payload = Data(repeating: 0xAA, count: 1_024)
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: payload)

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                responseBodyBufferingPolicy: .buffered(maxBytes: 8_192)
            ),
            session: mockSession
        )

        let received = try await client.request(DataEcho())
        #expect(received.count == payload.count)
    }

    @Test("Body equal to the limit is allowed (boundary inclusive)")
    func atLimitIsAllowed() async throws {
        let payload = Data(repeating: 0xBB, count: 4_096)
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: payload)

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                responseBodyBufferingPolicy: .buffered(maxBytes: 4_096)
            ),
            session: mockSession
        )

        let received = try await client.request(DataEcho())
        #expect(received.count == 4_096)
    }

    @Test("Body above the limit throws underlying error with limit and observed bytes")
    func overLimitThrows() async throws {
        let payload = Data(repeating: 0xCC, count: 5 * 1_024)
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: payload)

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                responseBodyBufferingPolicy: .buffered(maxBytes: 1_024)
            ),
            session: mockSession
        )

        do {
            _ = try await client.request(DataEcho())
            Issue.record("Expected response-too-large NetworkError.underlying")
        } catch let error as NetworkError {
            switch error {
            case .underlying(let underlying, _)
            where underlying.code == NetworkErrorCode.responseBodyLimitExceeded.rawValue:
                #expect(underlying.message.contains("\(payload.count)"))
                #expect(underlying.message.contains("1024"))
            default:
                Issue.record("Expected NetworkError.underlying with responseBodyLimitExceeded code, got \(error)")
            }
        }
    }

    @Test("MockURLSession preserves the safe-default 5 MiB response ceiling")
    func mockSessionPreservesSafeDefaultLimit() async throws {
        let limit: Int64 = 5 * 1_024 * 1_024
        let payload = Data(repeating: 0xCD, count: Int(limit + 1))
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: payload)

        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://api.example.com/v1")!),
            session: mockSession
        )

        await expectResponseTooLarge(limit: limit, observed: Int64(payload.count)) {
            _ = try await client.request(DataEcho())
        }
        #expect(mockSession.capturedRequest != nil)
    }

    @Test(
        "Oversized buffered responses fail before response side effects",
        arguments: [
            ResponseBodyBufferingPolicy.streaming(maxBytes: 1_024),
            .buffered(maxBytes: 1_024),
        ]
    )
    func oversizedBufferedResponseFailsBeforeResponseSideEffects(
        bufferingPolicy: ResponseBodyBufferingPolicy
    ) async throws {
        let payload = Data(repeating: 0xCE, count: 2_048)
        let session = MockURLSession()
        session.setMockResponse(statusCode: 200, data: payload)
        let eventCounter = ResponseEventCounter()
        let policyCounter = ExecutionPolicyResponseCounter()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                eventObservers: [eventCounter],
                customExecutionPolicies: [ResponseObservingExecutionPolicy(counter: policyCounter)],
                responseBodyBufferingPolicy: bufferingPolicy
            ),
            session: session
        )

        await expectResponseTooLarge(limit: 1_024, observed: Int64(payload.count)) {
            _ = try await client.request(DataEcho())
        }

        // Observer handlers run asynchronously after NetworkEventHub hands
        // events to its per-observer chain. Waiting for the terminal failure
        // creates a FIFO barrier: any incorrectly published response event
        // would have incremented the counter before this resumes.
        await eventCounter.waitForRequestFailure()
        #expect(await eventCounter.responseReceivedCount == 0)
        #expect(await policyCounter.responseCount == 0)
        #expect(session.capturedRequest != nil)
    }

    @Test("Fresh cache hit above the limit throws before decode")
    func oversizedFreshCacheHitThrows() async throws {
        let payload = Data(repeating: 0xEF, count: 5 * 1_024)
        let cache = InMemoryResponseCache()
        let request = URLRequest(url: URL(string: "https://api.example.com/v1/echo")!)
        let key = try #require(ResponseCacheKey(request: request))
        await cache.set(key, CachedResponse(data: payload))

        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data("unused".utf8))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                responseCachePolicy: .cacheFirst(maxAge: .seconds(600)),
                responseCache: cache,
                responseBodyBufferingPolicy: .buffered(maxBytes: 1_024)
            ),
            session: mockSession
        )

        await expectResponseTooLarge(observed: Int64(payload.count)) {
            _ = try await client.request(DataEcho())
        }
        #expect(mockSession.capturedRequest == nil)
    }

    @Test("Oversize response is not written to the response cache")
    func oversizeResponseDoesNotPoisonCache() async throws {
        let payload = Data(repeating: 0xEE, count: 5 * 1_024)
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: payload)

        let cache = InMemoryResponseCache()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                responseCachePolicy: .cacheFirst(maxAge: .seconds(600)),
                responseCache: cache,
                responseBodyBufferingPolicy: .buffered(maxBytes: 1_024)
            ),
            session: mockSession
        )

        do {
            _ = try await client.request(DataEcho())
            Issue.record("Expected response-too-large NetworkError.underlying")
        } catch is NetworkError {
            // Expected.
        }

        let request = URLRequest(url: URL(string: "https://api.example.com/v1/echo")!)
        if let key = ResponseCacheKey(request: request) {
            let cached = await cache.get(key)
            #expect(cached == nil, "Oversize response must not be cached")
        }
    }

    @Test("Stale background revalidation above the limit does not replace cache")
    func oversizedStaleRevalidationDoesNotReplaceCache() async throws {
        let stalePayload = Data("stale".utf8)
        let oversizedPayload = Data(repeating: 0xFA, count: 5 * 1_024)
        let cache = InMemoryResponseCache()
        let request = URLRequest(url: URL(string: "https://api.example.com/v1/echo")!)
        let key = try #require(ResponseCacheKey(request: request))
        await cache.set(
            key,
            CachedResponse(
                data: stalePayload,
                headers: ["ETag": "v1"],
                storedAt: Date(timeIntervalSinceNow: -5)
            )
        )

        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: oversizedPayload)
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                responseCachePolicy: .staleWhileRevalidate(maxAge: .seconds(1), staleWindow: .seconds(10)),
                responseCache: cache,
                responseBodyBufferingPolicy: .buffered(maxBytes: 1_024)
            ),
            session: mockSession
        )

        let received = try await client.request(DataEcho())

        #expect(received == stalePayload)
        try await waitUntil {
            mockSession.capturedRequest != nil
        }
        try await Task.sleep(for: .milliseconds(50))
        let cached = try #require(await cache.get(key))
        #expect(cached.data == stalePayload)
    }

    @Test("Response interceptor expansion above the limit throws before decode")
    func responseInterceptorExpansionThrows() async throws {
        let oversizedPayload = Data(repeating: 0xAB, count: 5 * 1_024)
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data("small".utf8))

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                responseInterceptors: [ReplacingResponseBody(data: oversizedPayload)],
                responseBodyBufferingPolicy: .buffered(maxBytes: 1_024)
            ),
            session: mockSession
        )

        await expectResponseTooLarge(observed: Int64(oversizedPayload.count)) {
            _ = try await client.request(DataEcho())
        }
    }

    @Test("willDecode expansion above the limit throws before decode")
    func willDecodeExpansionThrows() async throws {
        let oversizedPayload = Data(repeating: 0xCD, count: 5 * 1_024)
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data("small".utf8))

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                decodingInterceptors: [ReplacingDecodableData(data: oversizedPayload)],
                responseBodyBufferingPolicy: .buffered(maxBytes: 1_024)
            ),
            session: mockSession
        )

        await expectResponseTooLarge(observed: Int64(oversizedPayload.count)) {
            _ = try await client.request(DataEcho())
        }
    }

    @Test("nil limit (default) keeps the unbounded behaviour")
    func nilLimitIsUnbounded() async throws {
        let payload = Data(repeating: 0xDD, count: 10 * 1_024 * 1_024)
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: payload)

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        let received = try await client.request(DataEcho())
        #expect(received.count == payload.count)
    }

    @Test("NetworkConfiguration preserves the response buffering policy")
    func configurationPreservesBufferingPolicy() {
        let streaming = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            responseBodyBufferingPolicy: .streaming(maxBytes: 2_048)
        )
        #expect(streaming.responseBodyBufferingPolicy == .streaming(maxBytes: 2_048))
    }

    @Test("HEAD response metadata does not trigger Content-Length preflight")
    func headResponseSkipsContentLengthPreflight() throws {
        var request = URLRequest(url: URL(string: "https://api.example.com/metadata")!)
        request.httpMethod = HTTPMethod.head.rawValue
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "9223372036854775807"]
            )
        )

        #expect(RequestExecutor.responseMayCarryBody(request: request, response: response) == false)
    }

    @Test("RFC no-body statuses skip Content-Length preflight", arguments: [100, 101, 150, 199, 204, 205, 304])
    func noBodyStatusSkipsContentLengthPreflight(statusCode: Int) throws {
        var request = URLRequest(url: URL(string: "https://api.example.com/metadata")!)
        request.httpMethod = HTTPMethod.get.rawValue
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Length": "9223372036854775807"]
            )
        )

        #expect(RequestExecutor.responseMayCarryBody(request: request, response: response) == false)
    }

    @Test("Successful CONNECT ignores framing metadata")
    func successfulConnectSkipsContentLengthPreflight() throws {
        var request = URLRequest(url: URL(string: "https://api.example.com/tunnel")!)
        request.httpMethod = HTTPMethod.connect.rawValue
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "9223372036854775807"]
            )
        )

        #expect(RequestExecutor.responseMayCarryBody(request: request, response: response) == false)
    }

    @Test("Unsuccessful CONNECT may carry an ordinary response body")
    func unsuccessfulConnectRetainsContentLengthPreflight() throws {
        var request = URLRequest(url: URL(string: "https://api.example.com/tunnel")!)
        request.httpMethod = HTTPMethod.connect.rawValue
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 407,
                httpVersion: nil,
                headerFields: ["Content-Length": "4096"]
            )
        )

        #expect(RequestExecutor.responseMayCarryBody(request: request, response: response))
    }

    @Test("Ordinary responses retain Content-Length preflight")
    func ordinaryResponseRetainsContentLengthPreflight() throws {
        var request = URLRequest(url: URL(string: "https://api.example.com/body")!)
        request.httpMethod = HTTPMethod.get.rawValue
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "4096"]
            )
        )

        #expect(RequestExecutor.responseMayCarryBody(request: request, response: response))
    }

    private func expectResponseTooLarge(
        limit: Int64 = 1_024,
        observed: Int64,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected response-too-large NetworkError.underlying")
        } catch let error as NetworkError {
            switch error {
            case .underlying(let underlying, _)
            where underlying.code == NetworkErrorCode.responseBodyLimitExceeded.rawValue:
                #expect(underlying.message.contains("\(observed)"))
                #expect(underlying.message.contains("\(limit)"))
            default:
                Issue.record("Expected NetworkError.underlying with responseBodyLimitExceeded code, got \(error)")
            }
        } catch {
            Issue.record("Expected NetworkError.underlying with responseBodyLimitExceeded code, got \(error)")
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for asynchronous condition.")
    }
}
