import Foundation
import Testing
import SwiftProtobuf
@testable import InnoNetwork


// Test protobuf messages
struct TestUserRequest: SwiftProtobuf.Message, Sendable {
    var userID: Int32 = 0

    var unknownFields = SwiftProtobuf.UnknownStorage()

    init() {}

    init(userID: Int32) {
        self.userID = userID
    }

    static let protoMessageName: String = "TestUserRequest"

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularInt32Field(value: &userID)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if userID != 0 {
            try visitor.visitSingularInt32Field(value: userID, fieldNumber: 1)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? TestUserRequest else { return false }
        return userID == other.userID && unknownFields == other.unknownFields
    }
}


struct TestUserResponse: SwiftProtobuf.Message, Sendable {
    var userID: Int32 = 0
    var name: String = ""
    var email: String = ""

    var unknownFields = SwiftProtobuf.UnknownStorage()

    init() {}

    init(userID: Int32, name: String, email: String) {
        self.userID = userID
        self.name = name
        self.email = email
    }

    static let protoMessageName: String = "TestUserResponse"

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularInt32Field(value: &userID)
            case 2: try decoder.decodeSingularStringField(value: &name)
            case 3: try decoder.decodeSingularStringField(value: &email)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if userID != 0 {
            try visitor.visitSingularInt32Field(value: userID, fieldNumber: 1)
        }
        if !name.isEmpty {
            try visitor.visitSingularStringField(value: name, fieldNumber: 2)
        }
        if !email.isEmpty {
            try visitor.visitSingularStringField(value: email, fieldNumber: 3)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? TestUserResponse else { return false }
        return userID == other.userID &&
               name == other.name &&
               email == other.email &&
               unknownFields == other.unknownFields
    }
}


// Test API definition using protobuf
struct GetUserProtobuf: ProtobufAPIDefinition {
    typealias Parameter = TestUserRequest
    typealias APIResponse = TestUserResponse

    var method: HTTPMethod { .post }
    var path: String { "/user/protobuf" }
    let parameters: TestUserRequest?

    init(userID: Int32) {
        self.parameters = TestUserRequest(userID: userID)
    }
}


// GET request API definition
struct GetUserProtobufGET: ProtobufAPIDefinition {
    typealias Parameter = TestUserRequest
    typealias APIResponse = TestUserResponse

    var method: HTTPMethod { .get }
    var path: String { "/user/\(userID)" }
    let parameters: TestUserRequest? = nil
    let userID: Int32

    init(userID: Int32) {
        self.userID = userID
    }
}


// Empty response API definition
struct DeleteUserProtobuf: ProtobufAPIDefinition {
    typealias Parameter = TestUserRequest
    typealias APIResponse = EmptyResponse

    var method: HTTPMethod { .delete }
    var path: String { "/user/\(userID)" }
    let parameters: TestUserRequest? = nil
    let userID: Int32

    init(userID: Int32) {
        self.userID = userID
    }
}


// Request interceptor for testing
struct TestProtobufRequestInterceptor: RequestInterceptor {
    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        return request
    }
}


// Response interceptor for testing
struct TestProtobufResponseInterceptor: ResponseInterceptor {
    func adapt(_ response: Response, request: URLRequest) async throws -> Response {
        var modifiedResponse = response
        // Simple modification for testing
        return modifiedResponse
    }
}


// API definition with interceptors
struct GetUserProtobufWithInterceptors: ProtobufAPIDefinition {
    typealias Parameter = TestUserRequest
    typealias APIResponse = TestUserResponse

    var method: HTTPMethod { .post }
    var path: String { "/user/protobuf" }
    let parameters: TestUserRequest?
    var requestInterceptors: [RequestInterceptor] { [TestProtobufRequestInterceptor()] }
    var responseInterceptors: [ResponseInterceptor] { [TestProtobufResponseInterceptor()] }

    init(userID: Int32) {
        self.parameters = TestUserRequest(userID: userID)
    }
}


@Suite("Protobuf Network Tests")
struct ProtobufNetworkClientTests {

    @Test("Successful POST request with protobuf")
    func protobufPostRequestSuccess() async throws {
        let mockSession = MockURLSession()
        let expectedResponse = TestUserResponse(userID: 1, name: "Test User", email: "test@example.com")
        let protobufData = try expectedResponse.serializedData()
        mockSession.setMockResponse(statusCode: 200, data: protobufData)

        let client = try DefaultNetworkClient(
            configuration: TestAPIConfiguration(),
            session: mockSession
        )

        let response = try await client.protobufRequest(GetUserProtobuf(userID: 1))
        #expect(response.userID == 1)
        #expect(response.name == "Test User")
        #expect(response.email == "test@example.com")
        #expect(mockSession.capturedRequest?.httpMethod == "POST")
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/x-protobuf")
    }

    @Test("Successful GET request with protobuf")
    func protobufGetRequestSuccess() async throws {
        let mockSession = MockURLSession()
        let expectedResponse = TestUserResponse(userID: 42, name: "Jane Doe", email: "jane@example.com")
        let protobufData = try expectedResponse.serializedData()
        mockSession.setMockResponse(statusCode: 200, data: protobufData)

        let client = try DefaultNetworkClient(
            configuration: TestAPIConfiguration(),
            session: mockSession
        )

        let response = try await client.protobufRequest(GetUserProtobufGET(userID: 42))
        #expect(response.userID == 42)
        #expect(response.name == "Jane Doe")
        #expect(mockSession.capturedRequest?.httpMethod == "GET")
        #expect(mockSession.capturedRequest?.httpBody == nil)
    }

    @Test("HTTP 404 error throws NetworkError.statusCode")
    func protobuf404Error() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 404, data: Data())

        let client = try DefaultNetworkClient(
            configuration: TestAPIConfiguration(),
            session: mockSession
        )

        await #expect(throws: NetworkError.self) {
            try await client.protobufRequest(GetUserProtobuf(userID: 1))
        }
    }

    @Test("HTTP 500 error throws NetworkError.statusCode")
    func protobuf500Error() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 500, data: Data())

        let client = try DefaultNetworkClient(
            configuration: TestAPIConfiguration(),
            session: mockSession
        )

        await #expect(throws: NetworkError.self) {
            try await client.protobufRequest(GetUserProtobuf(userID: 1))
        }
    }

    @Test("Network error throws NetworkError.underlying")
    func protobufNetworkError() async throws {
        let mockSession = MockURLSession()
        mockSession.mockError = URLError(.notConnectedToInternet)

        let client = try DefaultNetworkClient(
            configuration: TestAPIConfiguration(),
            session: mockSession
        )

        await #expect(throws: NetworkError.self) {
            try await client.protobufRequest(GetUserProtobuf(userID: 1))
        }
    }

    @Test("Invalid protobuf data throws NetworkError.objectMapping")
    func protobufDecodingError() async throws {
        let mockSession = MockURLSession()
        let invalidData = "not a valid protobuf".data(using: .utf8)!
        mockSession.setMockResponse(statusCode: 200, data: invalidData)

        let client = try DefaultNetworkClient(
            configuration: TestAPIConfiguration(),
            session: mockSession
        )

        await #expect(throws: NetworkError.self) {
            try await client.protobufRequest(GetUserProtobuf(userID: 1))
        }
    }

    @Test("Empty response with 204 status code succeeds for EmptyResponse")
    func protobufEmptyResponseSuccess() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 204, data: Data())

        let client = try DefaultNetworkClient(
            configuration: TestAPIConfiguration(),
            session: mockSession
        )

        _ = try await client.protobufRequest(DeleteUserProtobuf(userID: 1))
        #expect(mockSession.capturedRequest?.httpMethod == "DELETE")
    }

    @Test("Empty data with 200 status succeeds for EmptyResponse")
    func protobufEmptyDataSuccess() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data())

        let client = try DefaultNetworkClient(
            configuration: TestAPIConfiguration(),
            session: mockSession
        )

        _ = try await client.protobufRequest(DeleteUserProtobuf(userID: 1))
    }

    @Test("Request interceptor modifies request")
    func protobufRequestInterceptor() async throws {
        let mockSession = MockURLSession()
        let expectedResponse = TestUserResponse(userID: 1, name: "Test", email: "test@example.com")
        let protobufData = try expectedResponse.serializedData()
        mockSession.setMockResponse(statusCode: 200, data: protobufData)

        let client = try DefaultNetworkClient(
            configuration: TestAPIConfiguration(),
            session: mockSession
        )

        _ = try await client.protobufRequest(GetUserProtobufWithInterceptors(userID: 1))

        let authHeader = mockSession.capturedRequest?.value(forHTTPHeaderField: "Authorization")
        #expect(authHeader == "Bearer test-token")
    }

    @Test("Protobuf message serialization and deserialization")
    func protobufSerializationTest() throws {
        // Test request serialization
        let request = TestUserRequest(userID: 42)
        let data = try request.serializedData()
        #expect(!data.isEmpty)

        // Test deserialization
        let decoded = try TestUserRequest(serializedData: data)
        #expect(decoded.userID == 42)

        // Test response serialization
        let response = TestUserResponse(userID: 100, name: "John", email: "john@test.com")
        let responseData = try response.serializedData()
        #expect(!responseData.isEmpty)

        let decodedResponse = try TestUserResponse(serializedData: responseData)
        #expect(decodedResponse.userID == 100)
        #expect(decodedResponse.name == "John")
        #expect(decodedResponse.email == "john@test.com")
    }

    @Test("Protobuf request body is properly encoded")
    func protobufRequestBodyEncoding() async throws {
        let mockSession = MockURLSession()
        let expectedResponse = TestUserResponse(userID: 1, name: "Test", email: "test@example.com")
        let protobufData = try expectedResponse.serializedData()
        mockSession.setMockResponse(statusCode: 200, data: protobufData)

        let client = try DefaultNetworkClient(
            configuration: TestAPIConfiguration(),
            session: mockSession
        )

        _ = try await client.protobufRequest(GetUserProtobuf(userID: 99))

        // Verify request body contains protobuf data
        let requestBody = try #require(mockSession.capturedRequest?.httpBody)
        #expect(!requestBody.isEmpty)

        // Verify we can decode it back
        let decodedRequest = try TestUserRequest(serializedData: requestBody)
        #expect(decodedRequest.userID == 99)
    }
}


@Suite("Protobuf Retry Policy Tests")
struct ProtobufRetryTests {

    @Test("Retry policy retries on network error")
    func retryOnNetworkError() async throws {
        final class RetryMockSession: URLSessionProtocol, @unchecked Sendable {
            var attemptCount = 0
            let maxAttempts = 2

            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                attemptCount += 1
                if attemptCount < maxAttempts {
                    throw URLError(.networkConnectionLost)
                }

                let response = TestUserResponse(userID: 1, name: "Success", email: "test@example.com")
                let data = try response.serializedData()
                let httpResponse = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (data, httpResponse)
            }
        }

        let mockSession = RetryMockSession()
        let retryPolicy = RetryPolicy(maxRetries: 3, retryDelay: 0.01)
        let networkConfig = NetworkConfiguration(
            baseURL: URL(string: "https://test.example.com")!,
            timeout: 30,
            cachePolicy: .useProtocolCachePolicy,
            retryPolicy: retryPolicy
        )

        let client = try DefaultNetworkClient(
            configuration: TestAPIConfiguration(),
            networkConfiguration: networkConfig,
            session: mockSession
        )

        let response = try await client.protobufRequest(GetUserProtobuf(userID: 1))
        #expect(response.userID == 1)
        #expect(mockSession.attemptCount == 2)
    }

    @Test("Retry policy stops after max retries")
    func stopAfterMaxRetries() async throws {
        final class AlwaysFailSession: URLSessionProtocol, @unchecked Sendable {
            var attemptCount = 0

            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                attemptCount += 1
                throw URLError(.networkConnectionLost)
            }
        }

        let mockSession = AlwaysFailSession()
        let retryPolicy = RetryPolicy(maxRetries: 2, retryDelay: 0.01)
        let networkConfig = NetworkConfiguration(
            baseURL: URL(string: "https://test.example.com")!,
            timeout: 30,
            cachePolicy: .useProtocolCachePolicy,
            retryPolicy: retryPolicy
        )

        let client = try DefaultNetworkClient(
            configuration: TestAPIConfiguration(),
            networkConfiguration: networkConfig,
            session: mockSession
        )

        await #expect(throws: NetworkError.self) {
            try await client.protobufRequest(GetUserProtobuf(userID: 1))
        }

        // Initial attempt + 2 retries = 3 total attempts
        #expect(mockSession.attemptCount == 3)
    }
}


struct TestAPIConfiguration: APIConfigure {
    var host: String { "https://test.example.com" }
    var basePath: String { "" }
}
