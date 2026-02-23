import Foundation
import os
@testable import InnoNetwork


private struct MockURLSessionState {
    var mockData: Data
    var mockResponse: URLResponse
    var mockError: URLError?
    var capturedRequest: URLRequest?
}


final class MockURLSession: URLSessionProtocol, Sendable {
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
            capturedRequest: nil
        )
    )

    var mockData: Data {
        get { stateLock.withLock { $0.mockData } }
        set { stateLock.withLock { $0.mockData = newValue } }
    }

    var mockResponse: URLResponse {
        get { stateLock.withLock { $0.mockResponse } }
        set { stateLock.withLock { $0.mockResponse = newValue } }
    }

    var mockError: URLError? {
        get { stateLock.withLock { $0.mockError } }
        set { stateLock.withLock { $0.mockError = newValue } }
    }

    var capturedRequest: URLRequest? {
        stateLock.withLock { $0.capturedRequest }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let snapshot = stateLock.withLock { state -> (Data, URLResponse, URLError?) in
            state.capturedRequest = request
            return (state.mockData, state.mockResponse, state.mockError)
        }
        if let error = snapshot.2 {
            throw error
        }
        return (snapshot.0, snapshot.1)
    }
    
    func setMockResponse(statusCode: Int, data: Data = Data()) {
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
    
    func setMockJSON<T: Encodable>(_ value: T, statusCode: Int = 200) throws {
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
