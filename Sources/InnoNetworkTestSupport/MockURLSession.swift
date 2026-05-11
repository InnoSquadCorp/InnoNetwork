import Foundation
import InnoNetwork
import os

/// One scripted reply for ``MockURLSession``.
///
/// Sequenced stubbing exists so retry/idempotency/refresh-token tests
/// can assert *ordering* — the first call returns a 503, the second a
/// 200 — instead of mutating a single mutable slot between calls.
public struct MockURLSessionResponse: Sendable {
    public var data: Data
    public var response: URLResponse
    public var error: URLError?

    public init(data: Data = Data(), response: URLResponse, error: URLError? = nil) {
        self.data = data
        self.response = response
        self.error = error
    }

    /// Convenience constructor for an HTTP response with status code and
    /// optional body.
    public static func http(
        statusCode: Int,
        data: Data = Data(),
        headers: [String: String]? = nil,
        url: URL = URL(string: "https://example.com")!
    ) -> MockURLSessionResponse {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
        return MockURLSessionResponse(data: data, response: response, error: nil)
    }

    /// Convenience constructor for a transport-level URLError. The
    /// `response` field is non-optional on `URLSessionProtocol`, so a
    /// placeholder is supplied; consumers see only `error` thrown.
    public static func failure(_ error: URLError) -> MockURLSessionResponse {
        let placeholder = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 0,
            httpVersion: nil,
            headerFields: nil
        )!
        return MockURLSessionResponse(data: Data(), response: placeholder, error: error)
    }
}

private struct MockURLSessionState {
    var mockData: Data
    var mockResponse: URLResponse
    var mockError: URLError?
    var capturedRequest: URLRequest?
    var capturedRequests: [URLRequest]
    var scriptedResponses: [MockURLSessionResponse]
}


/// In-memory ``URLSessionProtocol`` implementation for consumer tests.
public final class MockURLSession: URLSessionProtocol, Sendable {
    private let stateLock = OSAllocatedUnfairLock<MockURLSessionState>(
        initialState: MockURLSessionState(
            mockData: Data(),
            mockResponse: HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!,
            mockError: nil,
            capturedRequest: nil,
            capturedRequests: [],
            scriptedResponses: []
        )
    )

    public init() {}

    /// Replaces the response script with `responses`. The next call to
    /// `data(for:)` returns `responses[0]`, the call after that returns
    /// `responses[1]`, and so on. When the script is exhausted the
    /// session reverts to the single-slot `mockData`/`mockResponse`
    /// behaviour, which preserves source-compatibility with existing
    /// tests that only ever stub one reply.
    public func setScriptedResponses(_ responses: [MockURLSessionResponse]) {
        stateLock.withLock { $0.scriptedResponses = responses }
    }

    /// Appends `response` to the scripted queue. Useful when the test
    /// builds the script incrementally — e.g., one stub per retry
    /// attempt the system under test is expected to issue.
    public func enqueueScriptedResponse(_ response: MockURLSessionResponse) {
        stateLock.withLock { $0.scriptedResponses.append(response) }
    }

    /// Every captured request, in the order the session observed them.
    /// Preserved across the scripted queue and the single-slot fallback
    /// so retry-ordering tests can assert each attempt's request
    /// independently.
    public var capturedRequestsInOrder: [URLRequest] {
        stateLock.withLock { $0.capturedRequests }
    }

    public var mockData: Data {
        get { stateLock.withLock { $0.mockData } }
        set { stateLock.withLock { $0.mockData = newValue } }
    }

    public var mockResponse: URLResponse {
        get { stateLock.withLock { $0.mockResponse } }
        set { stateLock.withLock { $0.mockResponse = newValue } }
    }

    public var mockError: URLError? {
        get { stateLock.withLock { $0.mockError } }
        set { stateLock.withLock { $0.mockError = newValue } }
    }

    public var capturedRequest: URLRequest? {
        stateLock.withLock { $0.capturedRequest }
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let snapshot = stateLock.withLock { state -> (Data, URLResponse, URLError?) in
            state.capturedRequest = request
            state.capturedRequests.append(request)
            if !state.scriptedResponses.isEmpty {
                let next = state.scriptedResponses.removeFirst()
                return (next.data, next.response, next.error)
            }
            return (state.mockData, state.mockResponse, state.mockError)
        }
        if let error = snapshot.2 {
            throw error
        }
        return (snapshot.0, snapshot.1)
    }

    public func setMockResponse(statusCode: Int, data: Data = Data()) {
        stateLock.withLock { state in
            state.mockData = data
            state.mockResponse = HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
        }
    }

    public func setMockJSON<T: Encodable>(_ value: T, statusCode: Int = 200) throws {
        let encoded = try JSONEncoder().encode(value)
        stateLock.withLock { state in
            state.mockData = encoded
            state.mockResponse = HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
        }
    }
}
