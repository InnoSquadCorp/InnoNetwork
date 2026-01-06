import Foundation
@testable import InnoNetwork


final class MockURLSession: URLSessionProtocol, @unchecked Sendable {
    var mockData: Data = Data()
    var mockResponse: URLResponse = HTTPURLResponse(
        url: URL(string: "https://example.com")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )!
    var mockError: Error?
    var capturedRequest: URLRequest?

    private(set) var requestCount: Int = 0
    var failUntilAttempt: Int = 0
    var failureStatusCode: Int = 500
    var successData: Data?
    var successStatusCode: Int = 200

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequest = request
        requestCount += 1

        if let error = mockError {
            throw error
        }

        if failUntilAttempt > 0 && requestCount <= failUntilAttempt {
            let failResponse = HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: failureStatusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), failResponse)
        }

        if let successData = successData {
            let successResponse = HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: successStatusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (successData, successResponse)
        }

        return (mockData, mockResponse)
    }

    func reset() {
        requestCount = 0
        failUntilAttempt = 0
        mockError = nil
        successData = nil
    }
    
    func setMockResponse(statusCode: Int, data: Data = Data()) {
        mockData = data
        mockResponse = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
    
    func setMockJSON<T: Encodable>(_ value: T, statusCode: Int = 200) throws {
        mockData = try JSONEncoder().encode(value)
        mockResponse = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
