import Foundation
import os
import Testing

@testable import InnoNetwork

private struct ResilienceUser: Codable, Sendable, Equatable {
    let id: Int
    let name: String
}


private struct ResilienceGetRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = ResilienceUser

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
}

private struct CacheableEmptyRequest: APIDefinition, HTTPEmptyResponseDecodable {
    typealias Parameter = EmptyParameter
    typealias APIResponse = CacheableEmptyRequest

    var method: HTTPMethod { .get }
    var path: String { "/empty" }
    var acceptableStatusCodes: Set<Int>? { [204] }

    static func emptyResponseValue() -> CacheableEmptyRequest {
        CacheableEmptyRequest()
    }
}


private struct AuthorizedResilienceGetRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = ResilienceUser

    let token: String
    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
    var requestInterceptors: [RequestInterceptor] {
        [StaticAuthorizationInterceptor(token: token)]
    }
}


private struct InterceptedResilienceGetRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = ResilienceUser

    let interceptors: [RequestInterceptor]

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
    var requestInterceptors: [RequestInterceptor] { interceptors }
}

private actor ResponseRecorder {
    private var responses: [Response] = []

    func record(_ response: Response) {
        responses.append(response)
    }

    func response(at index: Int = 0) -> Response? {
        guard responses.indices.contains(index) else { return nil }
        return responses[index]
    }
}

private struct RecordingResponseInterceptor: ResponseInterceptor {
    let recorder: ResponseRecorder

    func adapt(_ urlResponse: Response, request: URLRequest) async throws -> Response {
        _ = request
        await recorder.record(urlResponse)
        return urlResponse
    }
}


private struct ResiliencePostRequest: APIDefinition {
    struct Body: Encodable, Sendable {
        let name: String
    }

    typealias Parameter = Body
    typealias APIResponse = ResilienceUser

    let parameters: Body?
    var method: HTTPMethod { .post }
    var path: String { "/users" }

    init(name: String = "Jane") {
        self.parameters = Body(name: name)
    }
}


private struct IdempotentResiliencePostRequest: APIDefinition {
    struct Body: Encodable, Sendable {
        let name: String
    }

    typealias Parameter = Body
    typealias APIResponse = ResilienceUser

    let parameters: Body?
    var method: HTTPMethod { .post }
    var path: String { "/users" }
    var headers: HTTPHeaders {
        var headers = HTTPHeaders.default
        headers.add(name: "Idempotency-Key", value: "create-user-1")
        return headers
    }

    init(name: String = "Jane") {
        self.parameters = Body(name: name)
    }
}


private struct HeaderSettingInterceptor: RequestInterceptor {
    let field: String
    let value: String

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue(value, forHTTPHeaderField: field)
        return request
    }
}


private struct StaticAuthorizationInterceptor: RequestInterceptor {
    let token: String

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}


private struct QueuedHTTPResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
}


private actor Counter {
    private var value = 0

    func increment() {
        value += 1
    }

    var count: Int {
        value
    }
}


private actor SequenceURLSessionState {
    private var queue: [QueuedHTTPResponse]
    private var requests: [URLRequest] = []
    private let delay: Duration

    init(queue: [QueuedHTTPResponse], delay: Duration) {
        self.queue = queue
        self.delay = delay
    }

    func record(_ request: URLRequest) -> Duration {
        requests.append(request)
        return delay
    }

    func dequeue() throws -> (Data, URLResponse) {
        guard !queue.isEmpty else {
            throw NetworkError.invalidRequestConfiguration("No queued response.")
        }
        let next = queue.removeFirst()
        return (next.data, next.response)
    }

    var requestCount: Int {
        requests.count
    }

    var capturedRequests: [URLRequest] {
        requests
    }
}


private final class SequenceURLSession: URLSessionProtocol, Sendable {
    private let state: SequenceURLSessionState

    init(queue: [QueuedHTTPResponse], delay: Duration = .zero) {
        self.state = SequenceURLSessionState(queue: queue, delay: delay)
    }

    var requestCount: Int {
        get async {
            await state.requestCount
        }
    }

    var capturedRequests: [URLRequest] {
        get async {
            await state.capturedRequests
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let delay = await state.record(request)
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return try await state.dequeue()
    }
}


private actor CancellationFirstURLSessionState {
    private var queue: [QueuedHTTPResponse]
    private var requests: [URLRequest] = []
    private var cancellationCount = 0

    init(queue: [QueuedHTTPResponse]) {
        self.queue = queue
    }

    func recordAndShouldWaitForCancellation(_ request: URLRequest) -> Bool {
        requests.append(request)
        return requests.count == 1
    }

    func recordCancellation() {
        cancellationCount += 1
    }

    func dequeue() throws -> (Data, URLResponse) {
        guard !queue.isEmpty else {
            throw NetworkError.invalidRequestConfiguration("No queued response.")
        }
        let next = queue.removeFirst()
        return (next.data, next.response)
    }

    var requestCount: Int {
        requests.count
    }

    var cancelledRequestCount: Int {
        cancellationCount
    }
}


private final class CancellationFirstURLSession: URLSessionProtocol, Sendable {
    private let state: CancellationFirstURLSessionState

    init(queue: [QueuedHTTPResponse]) {
        self.state = CancellationFirstURLSessionState(queue: queue)
    }

    var requestCount: Int {
        get async {
            await state.requestCount
        }
    }

    var cancelledRequestCount: Int {
        get async {
            await state.cancelledRequestCount
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let shouldWaitForCancellation = await state.recordAndShouldWaitForCancellation(request)

        if shouldWaitForCancellation {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                await state.recordCancellation()
                throw error
            }
            throw NetworkError.invalidRequestConfiguration("Expected the first queued request to be cancelled.")
        }

        return try await state.dequeue()
    }
}


private func queuedResponse(
    statusCode: Int,
    body: ResilienceUser? = nil,
    headers: [String: String] = [:]
) throws -> QueuedHTTPResponse {
    let data = try body.map { try JSONEncoder().encode($0) } ?? Data()
    return QueuedHTTPResponse(
        data: data,
        response: HTTPURLResponse(
            url: URL(string: "https://api.example.com/users/1")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    )
}


private let cacheFixtureAcceptLanguage = "en-US"


private func resilienceUserCacheKey() -> ResponseCacheKey {
    ResponseCacheKey(
        method: "GET",
        url: "https://api.example.com/users/1",
        headers: ["Accept-Language": cacheFixtureAcceptLanguage]
    )
}


private func responseHeader(_ response: Response, named name: String) -> String? {
    guard
        let pair = response.response?.allHeaderFields.first(where: { pair in
            guard let key = pair.key as? String else { return false }
            return key.caseInsensitiveCompare(name) == .orderedSame
        })
    else {
        return nil
    }
    return pair.value as? String ?? String(describing: pair.value)
}


private func makeLocalizedCacheConfiguration(
    responseCachePolicy: ResponseCachePolicy,
    responseCache: any ResponseCache,
    responseInterceptors: [ResponseInterceptor] = []
) -> NetworkConfiguration {
    NetworkConfiguration(
        baseURL: URL(string: "https://api.example.com")!,
        requestInterceptors: [
            HeaderSettingInterceptor(field: "Accept-Language", value: cacheFixtureAcceptLanguage)
        ],
        responseInterceptors: responseInterceptors,
        responseCachePolicy: responseCachePolicy,
        responseCache: responseCache
    )
}


@Suite("Resilience policies")
struct ResiliencePolicyTests {
    @Test("Refresh token policy replays one 401 response")
    func refreshPolicyReplaysOnce() async throws {
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 401),
            queuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "refreshed")),
        ])
        let refreshCount = Counter()
        let policy = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: {
                await refreshCount.increment()
                return "new"
            }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                refreshTokenPolicy: policy
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == ResilienceUser(id: 1, name: "refreshed"))
        #expect(await refreshCount.count == 1)
        #expect(await session.requestCount == 2)
        #expect(await session.capturedRequests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer new")
    }

    @Test("Refresh replay preserves interceptor-adapted request state")
    func refreshReplayPreservesAdaptedInterceptorHeaders() async throws {
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 401),
            queuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "refreshed")),
        ])
        let policy = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: { "new" }
        )
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "https://api.example.com")!,
                requestInterceptors: [
                    HeaderSettingInterceptor(field: "X-Tenant-ID", value: "tenant-a"),
                    HeaderSettingInterceptor(field: "X-Trace-ID", value: "trace-123"),
                ],
                refreshTokenPolicy: policy
            ),
            session: session
        )

        let user = try await client.request(
            InterceptedResilienceGetRequest(
                interceptors: [
                    HeaderSettingInterceptor(field: "X-Request-Signature", value: "signed")
                ]
            )
        )
        let capturedRequests = await session.capturedRequests

        #expect(user == ResilienceUser(id: 1, name: "refreshed"))
        #expect(capturedRequests.count == 2)
        #expect(capturedRequests[0].value(forHTTPHeaderField: "X-Tenant-ID") == "tenant-a")
        #expect(capturedRequests[0].value(forHTTPHeaderField: "X-Trace-ID") == "trace-123")
        #expect(capturedRequests[0].value(forHTTPHeaderField: "X-Request-Signature") == "signed")
        #expect(capturedRequests[1].value(forHTTPHeaderField: "X-Tenant-ID") == "tenant-a")
        #expect(capturedRequests[1].value(forHTTPHeaderField: "X-Trace-ID") == "trace-123")
        #expect(capturedRequests[1].value(forHTTPHeaderField: "X-Request-Signature") == "signed")
        #expect(capturedRequests[1].value(forHTTPHeaderField: "Authorization") == "Bearer new")
    }

    @Test("Concurrent 401 responses share one refresh")
    func refreshPolicySingleFlight() async throws {
        let body = ResilienceUser(id: 1, name: "ok")
        var responses: [QueuedHTTPResponse] = []
        for _ in 0..<10 {
            responses.append(try queuedResponse(statusCode: 401))
        }
        for _ in 0..<10 {
            responses.append(try queuedResponse(statusCode: 200, body: body))
        }
        let session = SequenceURLSession(queue: responses)
        let refreshCount = Counter()
        let policy = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: {
                await refreshCount.increment()
                try await Task.sleep(for: .milliseconds(50))
                return "new"
            }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                refreshTokenPolicy: policy
            ),
            session: session
        )

        try await withThrowingTaskGroup(of: ResilienceUser.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await client.request(ResilienceGetRequest())
                }
            }
            for try await user in group {
                #expect(user == body)
            }
        }

        #expect(await refreshCount.count == 1)
    }

    @Test("Cancelled refresh waiter does not cancel shared refresh")
    func cancelledRefreshWaiterDoesNotCancelSharedRefresh() async throws {
        let body = ResilienceUser(id: 1, name: "ok")
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 401),
            queuedResponse(statusCode: 401),
            queuedResponse(statusCode: 200, body: body),
        ])
        let refreshCount = Counter()
        let policy = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: {
                await refreshCount.increment()
                try await Task.sleep(for: .milliseconds(100))
                return "new"
            }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                refreshTokenPolicy: policy
            ),
            session: session
        )

        let cancelled = Task {
            try await client.request(ResilienceGetRequest())
        }
        try await waitUntil {
            await refreshCount.count == 1
        }
        let remaining = Task {
            try await client.request(ResilienceGetRequest())
        }
        cancelled.cancel()

        await expectCancelled(cancelled)
        let user = try await remaining.value

        #expect(user == body)
        #expect(await refreshCount.count == 1)
    }

    @Test("Refresh failure fans out to concurrent 401 waiters")
    func refreshFailureFansOut() async throws {
        var responses: [QueuedHTTPResponse] = []
        for _ in 0..<5 {
            responses.append(try queuedResponse(statusCode: 401))
        }
        let session = SequenceURLSession(queue: responses)
        let refreshCount = Counter()
        let policy = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: {
                await refreshCount.increment()
                try await Task.sleep(for: .milliseconds(50))
                throw NetworkError.invalidRequestConfiguration("refresh failed")
            }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                refreshTokenPolicy: policy
            ),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            try await withThrowingTaskGroup(of: ResilienceUser.self) { group in
                for _ in 0..<5 {
                    group.addTask {
                        try await client.request(ResilienceGetRequest())
                    }
                }
                for try await _ in group {}
            }
        }
        #expect(await refreshCount.count == 1)
        #expect(await session.requestCount == 5)
    }

    @Test("Replay stops after a second 401")
    func refreshPolicyStopsAfterReplay() async throws {
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 401),
            queuedResponse(statusCode: 401),
        ])
        let policy = RefreshTokenPolicy(currentToken: { "old" }, refreshToken: { "new" })
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                refreshTokenPolicy: policy
            ),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(ResilienceGetRequest())
        }
        #expect(await session.requestCount == 2)
    }

    @Test("Default retry policy does not retry unsafe methods without idempotency key")
    func defaultRetryPolicyDoesNotRetryPostWithoutIdempotencyKey() async throws {
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 503),
            queuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "unexpected")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: ExponentialBackoffRetryPolicy(maxRetries: 1, retryDelay: 0, jitterRatio: 0)
            ),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(ResiliencePostRequest())
        }
        #expect(await session.requestCount == 1)
    }

    @Test("Default retry policy retries unsafe methods with idempotency key")
    func defaultRetryPolicyRetriesPostWithIdempotencyKey() async throws {
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 503),
            queuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "created")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: ExponentialBackoffRetryPolicy(maxRetries: 1, retryDelay: 0, jitterRatio: 0)
            ),
            session: session
        )

        let user = try await client.request(IdempotentResiliencePostRequest())

        #expect(user == ResilienceUser(id: 1, name: "created"))
        #expect(await session.requestCount == 2)
        #expect(await session.capturedRequests.first?.value(forHTTPHeaderField: "Idempotency-Key") == "create-user-1")
    }

    @Test("Method-agnostic retry policy keeps legacy unsafe-method retry behavior")
    func methodAgnosticRetryPolicyRetriesPostWithoutIdempotencyKey() async throws {
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 503),
            queuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "legacy")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: ExponentialBackoffRetryPolicy(
                    maxRetries: 1,
                    retryDelay: 0,
                    jitterRatio: 0,
                    idempotencyPolicy: .methodAgnostic
                )
            ),
            session: session
        )

        let user = try await client.request(ResiliencePostRequest())

        #expect(user == ResilienceUser(id: 1, name: "legacy"))
        #expect(await session.requestCount == 2)
    }

    @Test("GET coalescing shares one transport")
    func getCoalescingSharesTransport() async throws {
        let session = try SequenceURLSession(
            queue: [queuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "shared"))],
            delay: .milliseconds(50)
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                requestCoalescingPolicy: .getOnly
            ),
            session: session
        )

        try await withThrowingTaskGroup(of: ResilienceUser.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await client.request(ResilienceGetRequest())
                }
            }
            for try await user in group {
                #expect(user == ResilienceUser(id: 1, name: "shared"))
            }
        }

        #expect(await session.requestCount == 1)
    }

    @Test("POST is not coalesced by getOnly policy")
    func postDoesNotCoalesceByDefault() async throws {
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "one")),
            queuedResponse(statusCode: 200, body: ResilienceUser(id: 2, name: "two")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                requestCoalescingPolicy: .getOnly
            ),
            session: session
        )

        _ = try await client.request(ResiliencePostRequest())
        _ = try await client.request(ResiliencePostRequest())

        #expect(await session.requestCount == 2)
    }

    @Test("Coalescing keeps different Authorization headers separate")
    func coalescingSeparatesAuthorizationHeaders() async throws {
        let session = try SequenceURLSession(
            queue: [
                queuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "one")),
                queuedResponse(statusCode: 200, body: ResilienceUser(id: 2, name: "two")),
            ],
            delay: .milliseconds(50)
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                requestCoalescingPolicy: .getOnly
            ),
            session: session
        )

        async let first = client.request(AuthorizedResilienceGetRequest(token: "one"))
        async let second = client.request(AuthorizedResilienceGetRequest(token: "two"))
        let users = try await [first, second]

        #expect(users.contains(ResilienceUser(id: 1, name: "one")))
        #expect(users.contains(ResilienceUser(id: 2, name: "two")))
        #expect(await session.requestCount == 2)
    }

    @Test("Partial coalescing waiter cancellation keeps remaining waiter alive")
    func partialCoalescingCancellationKeepsRemainingWaiterAlive() async throws {
        let session = try SequenceURLSession(
            queue: [queuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "shared"))],
            delay: .milliseconds(100)
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                requestCoalescingPolicy: .getOnly
            ),
            session: session
        )

        let cancelled = Task {
            try await client.request(ResilienceGetRequest())
        }
        let remaining = Task {
            try await client.request(ResilienceGetRequest())
        }

        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()

        await expectCancelled(cancelled)
        let user = try await remaining.value

        #expect(user == ResilienceUser(id: 1, name: "shared"))
        #expect(await session.requestCount == 1)
    }

    @Test("All coalescing waiter cancellation cancels shared transport")
    func allCoalescingCancellationCancelsSharedTransport() async throws {
        let session = try CancellationFirstURLSession(
            queue: [
                queuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "first"))
            ]
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                requestCoalescingPolicy: .getOnly
            ),
            session: session
        )

        let first = Task {
            try await client.request(ResilienceGetRequest())
        }
        let second = Task {
            try await client.request(ResilienceGetRequest())
        }

        try await waitUntil {
            await session.requestCount == 1
        }
        first.cancel()
        second.cancel()

        await expectCancelled(first)
        await expectCancelled(second)
        try await waitUntil {
            await session.cancelledRequestCount == 1
        }

        let recovered = try await client.request(ResilienceGetRequest())

        #expect(recovered == ResilienceUser(id: 1, name: "first"))
        #expect(await session.requestCount == 2)
    }

    @Test("Fresh cache returns without transport")
    func freshCacheShortCircuitsTransport() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let body = try JSONEncoder().encode(ResilienceUser(id: 1, name: "cached"))
        await cache.set(key, CachedResponse(data: body, headers: ["ETag": "v1"]))
        let session = SequenceURLSession(queue: [])
        let client = DefaultNetworkClient(
            configuration: makeLocalizedCacheConfiguration(
                responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
                responseCache: cache
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == ResilienceUser(id: 1, name: "cached"))
        #expect(await session.requestCount == 0)
    }

    @Test("ETag 304 response uses cached body")
    func etagNotModifiedUsesCachedBody() async throws {
        let cache = InMemoryResponseCache()
        let recorder = ResponseRecorder()
        let key = resilienceUserCacheKey()
        let body = try JSONEncoder().encode(ResilienceUser(id: 1, name: "cached"))
        let storedAt = Date(timeIntervalSinceNow: -60)
        await cache.set(
            key,
            CachedResponse(
                data: body,
                headers: ["ETag": "v1"],
                storedAt: storedAt
            )
        )
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 304, headers: ["ETag": "v2", "Cache-Control": "max-age=60"])
        ])
        let client = DefaultNetworkClient(
            configuration: makeLocalizedCacheConfiguration(
                responseCachePolicy: .cacheFirst(maxAge: .seconds(1)),
                responseCache: cache,
                responseInterceptors: [RecordingResponseInterceptor(recorder: recorder)]
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == ResilienceUser(id: 1, name: "cached"))
        #expect(await session.capturedRequests.first?.value(forHTTPHeaderField: "If-None-Match") == "v1")
        let observedResponse = try #require(await recorder.response())
        #expect(observedResponse.statusCode == 200)
        #expect(responseHeader(observedResponse, named: "ETag") == "v2")
        #expect(responseHeader(observedResponse, named: "Cache-Control") == "max-age=60")
        let refreshed = try #require(await cache.get(key))
        #expect(refreshed.etag == "v2")
        #expect(
            refreshed.headers.first { $0.key.caseInsensitiveCompare("Cache-Control") == .orderedSame }?.value
                == "max-age=60")
        #expect(refreshed.storedAt > storedAt)
    }

    @Test("304 carrying a different Vary header preserves the stored vary snapshot")
    func etagNotModifiedWithChangedVaryPreservesSnapshot() async throws {
        let cache = InMemoryResponseCache()
        let recorder = ResponseRecorder()
        let key = resilienceUserCacheKey()
        let body = try JSONEncoder().encode(ResilienceUser(id: 1, name: "cached"))
        let storedAt = Date(timeIntervalSinceNow: -60)
        await cache.set(
            key,
            CachedResponse(
                data: body,
                headers: ["ETag": "v1", "Vary": "Accept-Language"],
                storedAt: storedAt,
                varyHeaders: ["accept-language": cacheFixtureAcceptLanguage]
            )
        )
        let session = try SequenceURLSession(queue: [
            queuedResponse(
                statusCode: 304,
                headers: ["ETag": "v2", "Vary": "Accept"]
            )
        ])
        let client = DefaultNetworkClient(
            configuration: makeLocalizedCacheConfiguration(
                responseCachePolicy: .cacheFirst(maxAge: .seconds(1)),
                responseCache: cache,
                responseInterceptors: [RecordingResponseInterceptor(recorder: recorder)]
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == ResilienceUser(id: 1, name: "cached"))
        let observedResponse = try #require(await recorder.response())
        #expect(observedResponse.statusCode == 200)
        #expect(responseHeader(observedResponse, named: "Vary") == "Accept-Language")
        #expect(responseHeader(observedResponse, named: "ETag") == "v1")
        let refreshed = try #require(await cache.get(key))
        #expect(refreshed.varyHeaders == ["accept-language": cacheFixtureAcceptLanguage])
        #expect(
            refreshed.headers.first { $0.key.caseInsensitiveCompare("Vary") == .orderedSame }?.value
                == "Accept-Language"
        )
        #expect(refreshed.etag == "v1")
        #expect(refreshed.storedAt > storedAt)
    }

    @Test("SWR returns stale data and revalidates in the background")
    func staleWhileRevalidateUpdatesCache() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let staleBody = try JSONEncoder().encode(ResilienceUser(id: 1, name: "stale"))
        await cache.set(
            key,
            CachedResponse(
                data: staleBody,
                headers: ["ETag": "v1"],
                storedAt: Date(timeIntervalSinceNow: -5)
            )
        )
        let fresh = ResilienceUser(id: 1, name: "fresh")
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 200, body: fresh, headers: ["ETag": "v2"])
        ])
        let client = DefaultNetworkClient(
            configuration: makeLocalizedCacheConfiguration(
                responseCachePolicy: .staleWhileRevalidate(maxAge: .seconds(1), staleWindow: .seconds(10)),
                responseCache: cache
            ),
            session: session
        )

        let returned = try await client.request(ResilienceGetRequest())

        #expect(returned == ResilienceUser(id: 1, name: "stale"))
        try await waitUntil {
            guard let cached = await cache.get(key),
                let decoded = try? JSONDecoder().decode(ResilienceUser.self, from: cached.data)
            else {
                return false
            }
            return await session.requestCount == 1 && decoded == fresh
        }
        #expect(await session.capturedRequests.first?.value(forHTTPHeaderField: "If-None-Match") == "v1")
    }

    @Test("SWR background revalidation uses request coalescing")
    func staleWhileRevalidateBackgroundRevalidationCoalesces() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let stale = ResilienceUser(id: 1, name: "stale")
        let staleBody = try JSONEncoder().encode(stale)
        await cache.set(
            key,
            CachedResponse(
                data: staleBody,
                headers: ["ETag": "v1"],
                storedAt: Date(timeIntervalSinceNow: -5)
            )
        )
        let fresh = ResilienceUser(id: 1, name: "fresh")
        let session = try SequenceURLSession(
            queue: [
                queuedResponse(statusCode: 200, body: fresh, headers: ["ETag": "v2"])
            ],
            delay: .milliseconds(80)
        )
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "https://api.example.com")!,
                requestInterceptors: [
                    HeaderSettingInterceptor(field: "Accept-Language", value: cacheFixtureAcceptLanguage)
                ],
                requestCoalescingPolicy: .getOnly,
                responseCachePolicy: .staleWhileRevalidate(maxAge: .seconds(1), staleWindow: .seconds(10)),
                responseCache: cache
            ),
            session: session
        )

        async let first = client.request(ResilienceGetRequest())
        async let second = client.request(ResilienceGetRequest())
        let returned = try await [first, second]

        #expect(returned == [stale, stale])
        try await waitUntil {
            guard let cached = await cache.get(key),
                let decoded = try? JSONDecoder().decode(ResilienceUser.self, from: cached.data)
            else {
                return false
            }
            return await session.requestCount == 1 && decoded == fresh
        }
        #expect(await session.requestCount == 1)
    }

    @Test("SWR background revalidation is cancelled by cancelAll")
    func staleWhileRevalidateBackgroundTaskIsCancelledByCancelAll() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let stale = ResilienceUser(id: 1, name: "stale")
        let staleBody = try JSONEncoder().encode(stale)
        await cache.set(
            key,
            CachedResponse(
                data: staleBody,
                headers: ["ETag": "v1"],
                storedAt: Date(timeIntervalSinceNow: -5)
            )
        )
        let session = try SequenceURLSession(
            queue: [
                queuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "fresh"), headers: ["ETag": "v2"])
            ],
            delay: .milliseconds(200)
        )
        let client = DefaultNetworkClient(
            configuration: makeLocalizedCacheConfiguration(
                responseCachePolicy: .staleWhileRevalidate(maxAge: .seconds(1), staleWindow: .seconds(10)),
                responseCache: cache
            ),
            session: session
        )

        let returned = try await client.request(ResilienceGetRequest())

        #expect(returned == stale)
        try await waitUntil {
            await session.requestCount == 1
        }
        await client.cancelAll()
        try await Task.sleep(for: .milliseconds(250))
        let cached = await cache.get(key)
        let decoded = try #require(cached.flatMap { try? JSONDecoder().decode(ResilienceUser.self, from: $0.data) })
        #expect(decoded == stale)
    }

    @Test("Response cache keeps different Authorization headers separate")
    func responseCacheSeparatesAuthorizationHeaders() async throws {
        let cache = InMemoryResponseCache()
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "one")),
            queuedResponse(statusCode: 200, body: ResilienceUser(id: 2, name: "two")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
                responseCache: cache
            ),
            session: session
        )

        let first = try await client.request(AuthorizedResilienceGetRequest(token: "one"))
        let second = try await client.request(AuthorizedResilienceGetRequest(token: "two"))

        #expect(first == ResilienceUser(id: 1, name: "one"))
        #expect(second == ResilienceUser(id: 2, name: "two"))
        #expect(await session.requestCount == 2)
    }

    @Test("Response cache key fingerprints Authorization header values")
    func responseCacheKeyFingerprintsAuthorizationHeaderValues() {
        let first = ResponseCacheKey(
            method: "GET",
            url: "https://api.example.com/users/1",
            headers: ["Authorization": "Bearer secret-one"]
        )
        let second = ResponseCacheKey(
            method: "GET",
            url: "https://api.example.com/users/1",
            headers: ["Authorization": "Bearer secret-two"]
        )

        #expect(first != second)
        #expect(first.headers.contains { $0.contains("authorization:sha256:") })
        #expect(!first.headers.contains { $0.contains("secret-one") })
        #expect(!second.headers.contains { $0.contains("secret-two") })
    }

    @Test("Response cache key strips URL fragments")
    func responseCacheKeyStripsURLFragments() throws {
        var firstRequest = URLRequest(url: try #require(URL(string: "https://api.example.com/users/1#first")))
        firstRequest.httpMethod = "GET"
        var secondRequest = URLRequest(url: try #require(URL(string: "https://api.example.com/users/1#second")))
        secondRequest.httpMethod = "GET"

        let first = try #require(ResponseCacheKey(request: firstRequest))
        let second = try #require(ResponseCacheKey(request: secondRequest))

        #expect(first == second)
        #expect(first.url == "https://api.example.com/users/1")
    }

    @Test(
        "Response cache stores RFC-cacheable GET status codes",
        arguments: [203, 300, 301, 308, 404, 405, 410, 414, 501])
    func responseCacheStoresCacheableStatusCodes(statusCode: Int) async throws {
        let cache = InMemoryResponseCache()
        let body = ResilienceUser(id: statusCode, name: "cached-\(statusCode)")
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: statusCode, body: body)
        ])
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            acceptableStatusCodes: NetworkConfiguration.defaultAcceptableStatusCodes.union([statusCode]),
            requestInterceptors: [
                HeaderSettingInterceptor(field: "Accept-Language", value: cacheFixtureAcceptLanguage)
            ],
            responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
            responseCache: cache
        )
        let client = DefaultNetworkClient(configuration: configuration, session: session)

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == body)
        let stored = try #require(await cache.get(resilienceUserCacheKey()))
        #expect(stored.statusCode == statusCode)

        let cachedOnlySession = SequenceURLSession(queue: [])
        let cachedOnlyClient = DefaultNetworkClient(configuration: configuration, session: cachedOnlySession)
        let cachedUser = try await cachedOnlyClient.request(ResilienceGetRequest())

        #expect(cachedUser == body)
        #expect(await cachedOnlySession.requestCount == 0)
    }

    @Test("Response cache stores 204 responses without a body")
    func responseCacheStoresNoContentResponses() async throws {
        let cache = InMemoryResponseCache()
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 204)
        ])
        let configuration = makeLocalizedCacheConfiguration(
            responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
            responseCache: cache
        )
        let client = DefaultNetworkClient(configuration: configuration, session: session)

        _ = try await client.request(CacheableEmptyRequest())

        let stored = try #require(
            await cache.get(
                ResponseCacheKey(
                    method: "GET",
                    url: "https://api.example.com/empty",
                    headers: ["Accept-Language": cacheFixtureAcceptLanguage]
                )
            )
        )
        #expect(stored.statusCode == 204)
    }

    @Test("Cache-Control no-store invalidates existing cached entries and skips writes")
    func cacheControlNoStoreInvalidatesExistingEntry() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let staleBody = try JSONEncoder().encode(ResilienceUser(id: 1, name: "stale"))
        await cache.set(
            key,
            CachedResponse(
                data: staleBody,
                headers: ["ETag": "old"],
                storedAt: Date(timeIntervalSinceNow: -60)
            )
        )
        let fresh = ResilienceUser(id: 1, name: "fresh")
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 200, body: fresh, headers: ["Cache-Control": "max-age=60, no-store"])
        ])
        let client = DefaultNetworkClient(
            configuration: makeLocalizedCacheConfiguration(
                responseCachePolicy: .cacheFirst(maxAge: .seconds(1)),
                responseCache: cache
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == fresh)
        #expect(await cache.get(key) == nil)
    }

    @Test("Cache-Control no-cache entries are stored but always revalidated")
    func cacheControlNoCacheForcesRevalidation() async throws {
        let cache = InMemoryResponseCache()
        let cached = ResilienceUser(id: 1, name: "requires-revalidation")
        let initialSession = try SequenceURLSession(queue: [
            queuedResponse(
                statusCode: 200,
                body: cached,
                headers: ["ETag": "v1", "Cache-Control": "no-cache, max-age=60"]
            )
        ])
        let configuration = makeLocalizedCacheConfiguration(
            responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
            responseCache: cache
        )
        let initialClient = DefaultNetworkClient(configuration: configuration, session: initialSession)

        _ = try await initialClient.request(ResilienceGetRequest())

        let stored = try #require(await cache.get(resilienceUserCacheKey()))
        #expect(stored.requiresRevalidation)

        let revalidationSession = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 304, headers: ["ETag": "v2"])
        ])
        let revalidationClient = DefaultNetworkClient(configuration: configuration, session: revalidationSession)
        let user = try await revalidationClient.request(ResilienceGetRequest())

        #expect(user == cached)
        #expect(await revalidationSession.requestCount == 1)
        #expect(await revalidationSession.capturedRequests.first?.value(forHTTPHeaderField: "If-None-Match") == "v1")
    }

    @Test("Response cache keeps different Accept-Language headers separate")
    func responseCacheSeparatesAcceptLanguageHeaders() async throws {
        let cache = InMemoryResponseCache()
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "ko")),
            queuedResponse(statusCode: 200, body: ResilienceUser(id: 2, name: "en")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
                responseCache: cache
            ),
            session: session
        )

        let korean = try await client.request(
            InterceptedResilienceGetRequest(
                interceptors: [HeaderSettingInterceptor(field: "Accept-Language", value: "ko-KR")]
            )
        )
        let english = try await client.request(
            InterceptedResilienceGetRequest(
                interceptors: [HeaderSettingInterceptor(field: "Accept-Language", value: "en-US")]
            )
        )

        #expect(korean == ResilienceUser(id: 1, name: "ko"))
        #expect(english == ResilienceUser(id: 2, name: "en"))
        #expect(await session.requestCount == 2)
    }

    @Test("Network-only cache policy does not substitute cached 304 bodies")
    func networkOnlyDoesNotSubstituteNotModified() async throws {
        let cache = InMemoryResponseCache()
        let key = ResponseCacheKey(method: "GET", url: "https://api.example.com/users/1")
        let body = try JSONEncoder().encode(ResilienceUser(id: 1, name: "cached"))
        await cache.set(key, CachedResponse(data: body, headers: ["ETag": "v1"]))
        let session = try SequenceURLSession(queue: [queuedResponse(statusCode: 304)])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .networkOnly,
                responseCache: cache
            ),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(ResilienceGetRequest())
        }
        #expect(await session.capturedRequests.first?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test("Network-only cache policy does not write the response into the cache")
    func responseCacheNetworkOnlySkipsCacheWrite() async throws {
        let cache = InMemoryResponseCache()
        let body = ResilienceUser(id: 1, name: "fresh")
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 200, body: body, headers: ["ETag": "v1"])
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .networkOnly,
                responseCache: cache
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == body)
        let stored = await cache.get(
            ResponseCacheKey(method: "GET", url: "https://api.example.com/users/1")
        )
        #expect(stored == nil)
    }

    @Test("Circuit breaker opens after countable failure")
    func circuitBreakerOpens() async throws {
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 500),
            queuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "unused")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                circuitBreakerPolicy: CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1)
            ),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(ResilienceGetRequest())
        }
        await #expect(throws: NetworkError.self) {
            try await client.request(ResilienceGetRequest())
        }

        #expect(await session.requestCount == 1)
    }

    @Test("Circuit breaker policy normalizes invalid thresholds and durations")
    func circuitBreakerPolicyNormalizesInputs() {
        let capped = CircuitBreakerPolicy(
            failureThreshold: 10,
            windowSize: 2,
            resetAfter: .seconds(-1),
            maxResetAfter: .seconds(-2)
        )
        #expect(capped.windowSize == 2)
        #expect(capped.failureThreshold == 2)
        #expect(capped.resetAfter == .zero)
        #expect(capped.maxResetAfter == .zero)

        let minimum = CircuitBreakerPolicy(
            failureThreshold: 0,
            windowSize: 0,
            resetAfter: .seconds(5),
            maxResetAfter: .seconds(1)
        )
        #expect(minimum.windowSize == 1)
        #expect(minimum.failureThreshold == 1)
        #expect(minimum.resetAfter == .seconds(5))
        #expect(minimum.maxResetAfter == .seconds(5))
    }

    @Test("Refresh replay clears prior Authorization header before reapplying")
    func refreshTokenReplayClearsPreviousAuthorizationHeader() async throws {
        let coordinator = RefreshTokenCoordinator(
            policy: RefreshTokenPolicy(
                currentToken: { "old" },
                refreshToken: { "new" },
                applyToken: { token, request in
                    var request = request
                    request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    return request
                }
            )
        )
        var request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)
        request.setValue("Bearer old", forHTTPHeaderField: "Authorization")

        let applied = try await coordinator.refreshAndApply(to: request)

        #expect(applied.value(forHTTPHeaderField: "Authorization") == "Bearer new")
    }

    @Test("Failed refresh does not replay stale failure to subsequent callers when cooldown is disabled")
    func refreshTokenFailedRefreshDoesNotReplayStaleFailure() async throws {
        actor RefreshScript {
            var calls = 0
            func next() async throws -> String {
                calls += 1
                if calls == 1 {
                    throw NetworkError.invalidRequestConfiguration("first refresh fails")
                }
                return "fresh"
            }
        }
        let script = RefreshScript()
        let coordinator = RefreshTokenCoordinator(
            policy: RefreshTokenPolicy(
                failureCooldown: .disabled,
                currentToken: { "old" },
                refreshToken: { try await script.next() }
            )
        )
        let request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)

        await #expect(throws: NetworkError.self) {
            _ = try await coordinator.refreshAndApply(to: request)
        }
        let applied = try await coordinator.refreshAndApply(to: request)

        #expect(await script.calls == 2)
        #expect(applied.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    @Test("Refresh failure cooldown throttles subsequent callers within the cooldown window")
    func refreshTokenFailureCooldownThrottlesCallers() async throws {
        actor RefreshScript {
            var calls = 0
            func next() async throws -> String {
                calls += 1
                throw NetworkError.invalidRequestConfiguration("refresh keeps failing")
            }
        }
        let script = RefreshScript()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowBox = OSAllocatedUnfairLock<Date>(initialState: now)
        let coordinator = RefreshTokenCoordinator(
            policy: RefreshTokenPolicy(
                failureCooldown: .exponentialBackoff(base: 5, max: 60),
                currentToken: { "old" },
                refreshToken: { try await script.next() }
            ),
            now: { nowBox.withLock { $0 } }
        )
        let request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)

        // First call performs refresh and fails — opens cooldown for 5s.
        await #expect(throws: NetworkError.self) {
            _ = try await coordinator.refreshAndApply(to: request)
        }
        // Second call within cooldown window must throw cached error WITHOUT
        // invoking the refresh provider again.
        await #expect(throws: NetworkError.self) {
            _ = try await coordinator.refreshAndApply(to: request)
        }
        #expect(await script.calls == 1)

        // Advancing past the cooldown window allows another attempt.
        nowBox.withLock { $0 = now.addingTimeInterval(6) }
        await #expect(throws: NetworkError.self) {
            _ = try await coordinator.refreshAndApply(to: request)
        }
        #expect(await script.calls == 2)
    }

    @Test("RefreshAndApply strips lowercase Authorization header before reapplying the new token")
    func refreshTokenStripsCaseInsensitiveAuthorization() async throws {
        let coordinator = RefreshTokenCoordinator(
            policy: RefreshTokenPolicy(
                currentToken: { "old" },
                refreshToken: { "fresh" }
            )
        )
        var request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)
        // Manually planted lowercase header — without a case-insensitive strip
        // this would coexist with the new "Authorization" entry on the replay.
        request.setValue("Bearer stale", forHTTPHeaderField: "authorization")

        let applied = try await coordinator.refreshAndApply(to: request)
        let headers = applied.allHTTPHeaderFields ?? [:]
        let authHeaders = headers.filter { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }
        #expect(authHeaders.count == 1)
        #expect(authHeaders.first?.value == "Bearer fresh")
    }

    @Test("Half-open probe cancellation releases the host")
    func circuitBreakerHalfOpenProbeCancellationDoesNotTrap() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1, resetAfter: .zero)
        let request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)

        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        try await registry.prepare(request: request, policy: policy)
        await registry.recordCancellation(request: request, policy: policy)

        try await registry.prepare(request: request, policy: policy)
    }

    @Test("401 does not open circuit breaker")
    func authFailureDoesNotOpenCircuitBreaker() async throws {
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 401),
            queuedResponse(statusCode: 401),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                circuitBreakerPolicy: CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1)
            ),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(ResilienceGetRequest())
        }
        await #expect(throws: NetworkError.self) {
            try await client.request(ResilienceGetRequest())
        }

        #expect(await session.requestCount == 2)
    }

    @Test("Half-open probe receiving 4xx releases the probe slot")
    func circuitBreakerHalfOpenProbe4xxReleasesSlot() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1, resetAfter: .zero)
        let request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)

        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        // prepare(...) transitions open → halfOpen(probeInFlight: true) once
        // resetAfter (here .zero) elapses.
        try await registry.prepare(request: request, policy: policy)
        // The probe came back with 404 — semantic failure, but the transport
        // worked. The slot must be released so subsequent traffic is admitted.
        await registry.recordStatus(request: request, policy: policy, statusCode: 404)

        try await registry.prepare(request: request, policy: policy)
    }

    @Test("4xx response does not reset accumulated transport failures")
    func circuitBreakerWindowSurvivesInterleaved4xx() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 3, windowSize: 3)
        let request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)

        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        // A 4xx between transport failures must not reset the rolling window.
        await registry.recordStatus(request: request, policy: policy, statusCode: 404)
        await registry.recordStatus(request: request, policy: policy, statusCode: 500)

        await #expect(throws: NetworkError.self) {
            try await registry.prepare(request: request, policy: policy)
        }
    }

    @Test("2xx response closes the circuit and clears failures")
    func circuitBreakerSuccessClosesCircuit() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 3, windowSize: 3)
        let request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)

        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        await registry.recordStatus(request: request, policy: policy, statusCode: 200)
        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        await registry.recordStatus(request: request, policy: policy, statusCode: 500)

        try await registry.prepare(request: request, policy: policy)
    }

    @Test("Coalesced transport failure counts once for circuit breaker")
    func coalescedFailureCountsOnceForCircuitBreaker() async throws {
        let session = try SequenceURLSession(
            queue: [
                queuedResponse(statusCode: 500),
                queuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "recovered")),
            ],
            delay: .milliseconds(50)
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                requestCoalescingPolicy: .getOnly,
                circuitBreakerPolicy: CircuitBreakerPolicy(failureThreshold: 2, windowSize: 2)
            ),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            try await withThrowingTaskGroup(of: ResilienceUser.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        try await client.request(ResilienceGetRequest())
                    }
                }
                for try await _ in group {}
            }
        }

        let recovered = try await client.request(ResilienceGetRequest())

        #expect(recovered == ResilienceUser(id: 1, name: "recovered"))
        #expect(await session.requestCount == 2)
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

    private func expectCancelled(_ task: Task<ResilienceUser, Error>) async {
        do {
            _ = try await task.value
            Issue.record("Expected request cancellation.")
        } catch NetworkError.cancelled {
            return
        } catch {
            Issue.record("Expected NetworkError.cancelled, got \(error).")
        }
    }
}
