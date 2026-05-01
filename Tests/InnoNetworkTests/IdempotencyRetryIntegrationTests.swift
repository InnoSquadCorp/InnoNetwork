import Foundation
import Testing

@testable import InnoNetwork

// MARK: - Fixtures

private struct CreatedUser: Codable, Sendable, Equatable {
    let id: Int
    let name: String
}


private struct PlainPost: APIDefinition {
    struct Body: Encodable, Sendable {
        let name: String
    }

    typealias Parameter = Body
    typealias APIResponse = CreatedUser

    let parameters: Body?
    var method: HTTPMethod { .post }
    var path: String { "/users" }

    init(name: String = "Jane") {
        self.parameters = Body(name: name)
    }
}


private struct IdempotentPost: APIDefinition {
    struct Body: Encodable, Sendable {
        let name: String
    }

    typealias Parameter = Body
    typealias APIResponse = CreatedUser

    let parameters: Body?
    let key: String
    var method: HTTPMethod { .post }
    var path: String { "/users" }
    var headers: HTTPHeaders {
        var headers = HTTPHeaders.default
        headers.add(name: "Idempotency-Key", value: key)
        return headers
    }

    init(name: String = "Jane", key: String = "create-user-1") {
        self.parameters = Body(name: name)
        self.key = key
    }
}


private struct QueuedHTTPResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
}


private actor SequenceState {
    private var queue: [QueuedHTTPResponse]
    private var requests: [URLRequest] = []

    init(queue: [QueuedHTTPResponse]) {
        self.queue = queue
    }

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    func dequeue() throws -> (Data, URLResponse) {
        guard !queue.isEmpty else {
            throw NetworkError.invalidRequestConfiguration("No queued response.")
        }
        let next = queue.removeFirst()
        return (next.data, next.response)
    }

    var requestCount: Int { requests.count }
    var capturedRequests: [URLRequest] { requests }
}


private final class SequenceSession: URLSessionProtocol, Sendable {
    private let state: SequenceState

    init(queue: [QueuedHTTPResponse]) {
        self.state = SequenceState(queue: queue)
    }

    var requestCount: Int { get async { await state.requestCount } }
    var capturedRequests: [URLRequest] { get async { await state.capturedRequests } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await state.record(request)
        return try await state.dequeue()
    }

    func upload(for request: URLRequest, from bodyData: Data) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}


private func queued(
    statusCode: Int,
    body: CreatedUser? = nil,
    headers: [String: String] = [:]
) throws -> QueuedHTTPResponse {
    let data = try body.map { try JSONEncoder().encode($0) } ?? Data()
    return QueuedHTTPResponse(
        data: data,
        response: HTTPURLResponse(
            url: URL(string: "https://api.example.com/users")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    )
}


// MARK: - Tests

@Suite("POST 503 + Retry-After + Idempotency-Key integration (P1.13)")
struct IdempotencyRetryIntegrationTests {

    @Test("POST 503 + Retry-After + Idempotency-Key → retry with same key")
    func postWith503AndRetryAfterAndIdempotencyKeyRetries() async throws {
        let session = try SequenceSession(queue: [
            queued(statusCode: 503, headers: ["Retry-After": "0"]),
            queued(statusCode: 200, body: CreatedUser(id: 1, name: "created")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: ExponentialBackoffRetryPolicy(
                    maxRetries: 1,
                    retryDelay: 0,
                    jitterRatio: 0
                )
            ),
            session: session
        )

        let user = try await client.request(IdempotentPost(key: "ABC-123"))

        #expect(user == CreatedUser(id: 1, name: "created"))
        #expect(await session.requestCount == 2)

        let captured = await session.capturedRequests
        let firstKey = captured.first?.value(forHTTPHeaderField: "Idempotency-Key")
        let secondKey = captured.last?.value(forHTTPHeaderField: "Idempotency-Key")
        #expect(firstKey == "ABC-123")
        #expect(secondKey == "ABC-123", "retried request must reuse the original Idempotency-Key")
    }

    @Test("POST 503 + Retry-After + no Idempotency-Key → no retry (default policy)")
    func postWith503AndRetryAfterButNoIdempotencyKeyDoesNotRetry() async throws {
        let session = try SequenceSession(queue: [
            queued(statusCode: 503, headers: ["Retry-After": "0"]),
            queued(statusCode: 200, body: CreatedUser(id: 99, name: "should-not-be-served")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: ExponentialBackoffRetryPolicy(
                    maxRetries: 1,
                    retryDelay: 0,
                    jitterRatio: 0
                )
            ),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(PlainPost())
        }
        #expect(await session.requestCount == 1, "POST without Idempotency-Key must not retry")
    }

    @Test("POST 503 with no Retry-After but Idempotency-Key → exponential backoff retry")
    func postWith503ButNoRetryAfterFallsBackToBackoff() async throws {
        let session = try SequenceSession(queue: [
            queued(statusCode: 503),
            queued(statusCode: 200, body: CreatedUser(id: 2, name: "backoff-retried")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: ExponentialBackoffRetryPolicy(
                    maxRetries: 1,
                    retryDelay: 0,
                    jitterRatio: 0
                )
            ),
            session: session
        )

        let user = try await client.request(IdempotentPost(key: "BACKOFF-1"))
        #expect(user == CreatedUser(id: 2, name: "backoff-retried"))
        #expect(await session.requestCount == 2)
    }

    @Test("Retry-After RFC 1123 absolute date in the past parses to nil → fallback delay")
    func retryAfterAbsoluteDateInThePastFallsBack() async throws {
        // RFC 1123 IMF-fixdate from 1994 — strictly in the past — must
        // parse as nil so the coordinator falls back to the policy's own
        // backoff (verified end-to-end via a successful POST retry).
        let session = try SequenceSession(queue: [
            queued(
                statusCode: 503,
                headers: ["Retry-After": "Sun, 06 Nov 1994 08:49:37 GMT"]
            ),
            queued(statusCode: 200, body: CreatedUser(id: 3, name: "past-date")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: ExponentialBackoffRetryPolicy(
                    maxRetries: 1,
                    retryDelay: 0,
                    jitterRatio: 0
                )
            ),
            session: session
        )

        let user = try await client.request(IdempotentPost(key: "PAST-1"))
        #expect(user == CreatedUser(id: 3, name: "past-date"))
        #expect(await session.requestCount == 2)

        // The parser itself returns nil for past dates — locked here so
        // the fallback semantics above can never silently regress.
        let parsed = ExponentialBackoffRetryPolicy.parseRetryAfter(
            "Sun, 06 Nov 1994 08:49:37 GMT"
        )
        #expect(parsed == nil)
    }

    @Test("Retry-After RFC 1123 absolute date in the future parses to a positive delta")
    func retryAfterAbsoluteDateInTheFutureParses() {
        let now = Date(timeIntervalSince1970: 0)
        // 1970-01-01 00:00:30 GMT — 30s after `now`.
        let parsed = ExponentialBackoffRetryPolicy.parseRetryAfter(
            "Thu, 01 Jan 1970 00:00:30 GMT",
            now: now
        )
        #expect(parsed == 30)
    }
}
