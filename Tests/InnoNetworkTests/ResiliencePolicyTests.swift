import Foundation
import Testing
import os

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


private struct SequenceURLSessionState {
    var queue: [QueuedHTTPResponse]
    var requests: [URLRequest] = []
    var delay: Duration
}


private final class SequenceURLSession: URLSessionProtocol, Sendable {
    private let state: OSAllocatedUnfairLock<SequenceURLSessionState>

    init(queue: [QueuedHTTPResponse], delay: Duration = .zero) {
        self.state = OSAllocatedUnfairLock(initialState: SequenceURLSessionState(queue: queue, delay: delay))
    }

    var requestCount: Int {
        state.withLock { $0.requests.count }
    }

    var capturedRequests: [URLRequest] {
        state.withLock { $0.requests }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let delay = state.withLock { state -> Duration in
            state.requests.append(request)
            return state.delay
        }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return try state.withLock { state in
            guard !state.queue.isEmpty else {
                throw NetworkError.invalidRequestConfiguration("No queued response.")
            }
            let next = state.queue.removeFirst()
            return (next.data, next.response)
        }
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


@Suite("Resilience policies")
struct ResiliencePolicyTests {
    @Test("Refresh token policy replays one 401 response")
    func refreshPolicyReplaysOnce() async throws {
        let session = try SequenceURLSession(queue: [
            queuedResponse(statusCode: 401),
            queuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "refreshed")),
        ])
        let refreshCount = OSAllocatedUnfairLock(initialState: 0)
        let policy = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: {
                refreshCount.withLock { $0 += 1 }
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
        #expect(refreshCount.withLock { $0 } == 1)
        #expect(session.requestCount == 2)
        #expect(session.capturedRequests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer new")
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
        let refreshCount = OSAllocatedUnfairLock(initialState: 0)
        let policy = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: {
                refreshCount.withLock { $0 += 1 }
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

        #expect(refreshCount.withLock { $0 } == 1)
    }

    @Test("Refresh failure fans out to concurrent 401 waiters")
    func refreshFailureFansOut() async throws {
        var responses: [QueuedHTTPResponse] = []
        for _ in 0..<5 {
            responses.append(try queuedResponse(statusCode: 401))
        }
        let session = SequenceURLSession(queue: responses)
        let refreshCount = OSAllocatedUnfairLock(initialState: 0)
        let policy = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: {
                refreshCount.withLock { $0 += 1 }
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
        #expect(refreshCount.withLock { $0 } == 1)
        #expect(session.requestCount == 5)
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
        #expect(session.requestCount == 2)
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

        #expect(session.requestCount == 1)
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

        #expect(session.requestCount == 2)
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
        #expect(session.requestCount == 2)
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
        #expect(session.requestCount == 1)
    }

    @Test("All coalescing waiter cancellation cancels shared transport")
    func allCoalescingCancellationCancelsSharedTransport() async throws {
        let session = try SequenceURLSession(
            queue: [
                queuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "first")),
                queuedResponse(statusCode: 200, body: ResilienceUser(id: 2, name: "second")),
            ],
            delay: .milliseconds(100)
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

        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        second.cancel()

        await expectCancelled(first)
        await expectCancelled(second)

        let recovered = try await client.request(ResilienceGetRequest())

        #expect(recovered == ResilienceUser(id: 1, name: "first"))
        #expect(session.requestCount == 2)
    }

    @Test("Fresh cache returns without transport")
    func freshCacheShortCircuitsTransport() async throws {
        let cache = InMemoryResponseCache()
        let key = ResponseCacheKey(method: "GET", url: "https://api.example.com/users/1")
        let body = try JSONEncoder().encode(ResilienceUser(id: 1, name: "cached"))
        await cache.set(key, CachedResponse(data: body, headers: ["ETag": "v1"]))
        let session = SequenceURLSession(queue: [])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
                responseCache: cache
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == ResilienceUser(id: 1, name: "cached"))
        #expect(session.requestCount == 0)
    }

    @Test("ETag 304 response uses cached body")
    func etagNotModifiedUsesCachedBody() async throws {
        let cache = InMemoryResponseCache()
        let key = ResponseCacheKey(method: "GET", url: "https://api.example.com/users/1")
        let body = try JSONEncoder().encode(ResilienceUser(id: 1, name: "cached"))
        await cache.set(
            key,
            CachedResponse(
                data: body,
                headers: ["ETag": "v1"],
                storedAt: Date(timeIntervalSinceNow: -60)
            )
        )
        let session = try SequenceURLSession(queue: [queuedResponse(statusCode: 304)])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .cacheFirst(maxAge: .seconds(1)),
                responseCache: cache
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == ResilienceUser(id: 1, name: "cached"))
        #expect(session.capturedRequests.first?.value(forHTTPHeaderField: "If-None-Match") == "v1")
    }

    @Test("SWR returns stale data and revalidates in the background")
    func staleWhileRevalidateUpdatesCache() async throws {
        let cache = InMemoryResponseCache()
        let key = ResponseCacheKey(method: "GET", url: "https://api.example.com/users/1")
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
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
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
            return session.requestCount == 1 && decoded == fresh
        }
        #expect(session.capturedRequests.first?.value(forHTTPHeaderField: "If-None-Match") == "v1")
    }

    @Test("SWR background revalidation is cancelled by cancelAll")
    func staleWhileRevalidateBackgroundTaskIsCancelledByCancelAll() async throws {
        let cache = InMemoryResponseCache()
        let key = ResponseCacheKey(method: "GET", url: "https://api.example.com/users/1")
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
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .staleWhileRevalidate(maxAge: .seconds(1), staleWindow: .seconds(10)),
                responseCache: cache
            ),
            session: session
        )

        let returned = try await client.request(ResilienceGetRequest())

        #expect(returned == stale)
        try await waitUntil {
            session.requestCount == 1
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
        #expect(session.requestCount == 2)
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
        #expect(session.capturedRequests.first?.value(forHTTPHeaderField: "If-None-Match") == nil)
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

        #expect(session.requestCount == 1)
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

        #expect(session.requestCount == 2)
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
        #expect(session.requestCount == 2)
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
        } catch {
            Issue.record("Expected NetworkError.cancelled, got \(error).")
        }
    }
}
