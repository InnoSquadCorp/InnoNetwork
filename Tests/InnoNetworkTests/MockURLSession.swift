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

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequest = request
        if let error = mockError {
            throw error
        }
        return (mockData, mockResponse)
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
