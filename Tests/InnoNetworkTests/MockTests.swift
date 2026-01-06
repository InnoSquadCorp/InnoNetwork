import Foundation
import Testing
@testable import InnoNetwork


struct MockTestAPI: APIConfigure {
    var host: String { "https://api.example.com" }
    var basePath: String { "v1" }
}


struct SimpleGetRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = MockUser
    
    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
}


struct SimplePostRequest: APIDefinition {
    struct PostParam: Encodable, Sendable {
        let name: String
        let email: String
    }
    
    typealias Parameter = PostParam
    typealias APIResponse = MockUser
    
    var parameters: PostParam?
    var method: HTTPMethod { .post }
    var path: String { "/users" }
    
    init(name: String, email: String) {
        self.parameters = PostParam(name: name, email: email)
    }
}


struct MockUser: Codable, Sendable, Equatable {
    let id: Int
    let name: String
    let email: String
}


@Suite("Mock-based Network Tests")
struct MockNetworkTests {
    
    @Test("Successful GET request with mock session")
    func successfulGetRequest() async throws {
        let mockSession = MockURLSession()
        let expectedUser = MockUser(id: 1, name: "John", email: "john@example.com")
        try mockSession.setMockJSON(expectedUser)
        
        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            session: mockSession
        )
        
        let result = try await client.request(SimpleGetRequest())
        
        #expect(result == expectedUser)
        #expect(mockSession.capturedRequest?.httpMethod == "GET")
        #expect(mockSession.capturedRequest?.url?.absoluteString.contains("/users/1") == true)
    }
    
    @Test("Successful POST request with mock session")
    func successfulPostRequest() async throws {
        let mockSession = MockURLSession()
        let expectedUser = MockUser(id: 2, name: "Jane", email: "jane@example.com")
        try mockSession.setMockJSON(expectedUser, statusCode: 201)
        
        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            session: mockSession
        )
        
        let result = try await client.request(SimplePostRequest(name: "Jane", email: "jane@example.com"))
        
        #expect(result == expectedUser)
        #expect(mockSession.capturedRequest?.httpMethod == "POST")
        #expect(mockSession.capturedRequest?.httpBody != nil)
    }
    
    @Test("HTTP error status code throws NetworkError.statusCode")
    func httpErrorStatusCode() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 404)
        
        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            session: mockSession
        )
        
        await #expect(throws: NetworkError.self) {
            try await client.request(SimpleGetRequest())
        }
    }
    
    @Test("Network error throws NetworkError.underlying")
    func networkError() async throws {
        let mockSession = MockURLSession()
        mockSession.mockError = URLError(.notConnectedToInternet)
        
        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            session: mockSession
        )
        
        await #expect(throws: NetworkError.self) {
            try await client.request(SimpleGetRequest())
        }
    }
    
    @Test("Decoding error throws NetworkError.objectMapping")
    func decodingError() async throws {
        let mockSession = MockURLSession()
        mockSession.mockData = "invalid json".data(using: .utf8)!
        mockSession.setMockResponse(statusCode: 200, data: "invalid json".data(using: .utf8)!)
        
        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            session: mockSession
        )
        
        await #expect(throws: NetworkError.self) {
            try await client.request(SimpleGetRequest())
        }
    }
    
    @Test("Empty response for EmptyResponse type succeeds")
    func emptyResponseSuccess() async throws {
        struct EmptyDeleteRequest: APIDefinition {
            typealias Parameter = EmptyParameter
            typealias APIResponse = EmptyResponse
            
            var method: HTTPMethod { .delete }
            var path: String { "/users/1" }
        }
        
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 204, data: Data())
        
        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            session: mockSession
        )
        
        _ = try await client.request(EmptyDeleteRequest())
    }
}


@Suite("Query Parameter Encoding Tests")
struct QueryParameterTests {
    
    @Test("Array parameters are encoded correctly")
    func arrayParameterEncoding() {
        struct ArrayParam: Encodable {
            let tags: [String]
        }
        
        let param = ArrayParam(tags: ["swift", "ios", "network"])
        let queryItems = param.encodedQueryItems
        
        #expect(queryItems.count == 3)
        #expect(queryItems.contains { $0.name == "tags[0]" && $0.value == "swift" })
        #expect(queryItems.contains { $0.name == "tags[1]" && $0.value == "ios" })
        #expect(queryItems.contains { $0.name == "tags[2]" && $0.value == "network" })
    }
    
    @Test("Nested object parameters are encoded correctly")
    func nestedObjectEncoding() {
        struct NestedParam: Encodable {
            struct Filter: Encodable {
                let minAge: Int
                let maxAge: Int
            }
            let filter: Filter
        }
        
        let param = NestedParam(filter: .init(minAge: 18, maxAge: 65))
        let queryItems = param.encodedQueryItems
        
        #expect(queryItems.contains { $0.name == "filter[minAge]" && $0.value == "18" })
        #expect(queryItems.contains { $0.name == "filter[maxAge]" && $0.value == "65" })
    }
    
    @Test("Boolean parameters are encoded as true/false")
    func booleanEncoding() {
        struct BoolParam: Encodable {
            let active: Bool
            let verified: Bool
        }
        
        let param = BoolParam(active: true, verified: false)
        let queryItems = param.encodedQueryItems
        
        #expect(queryItems.contains { $0.name == "active" && $0.value == "true" })
        #expect(queryItems.contains { $0.name == "verified" && $0.value == "false" })
    }
}


@Suite("Form URL-Encoded Tests")
struct FormURLEncodedTests {
    
    @Test("Form URL-encoded data is encoded correctly")
    func formURLEncodedEncoding() throws {
        struct LoginParam: Encodable {
            let username: String
            let password: String
        }
        
        let param = LoginParam(username: "testuser", password: "secret123")
        let data = try #require(param.formURLEncodedData)
        let string = try #require(String(data: data, encoding: .utf8))
        #expect(string.contains("username=testuser"))
        #expect(string.contains("password=secret123"))
    }
    
    @Test("Form URL-encoded request uses correct content type")
    func formURLEncodedContentType() async throws {
        struct FormLoginRequest: APIDefinition {
            struct LoginParam: Encodable, Sendable {
                let username: String
                let password: String
            }
            
            typealias Parameter = LoginParam
            typealias APIResponse = MockUser
            
            var parameters: LoginParam?
            var method: HTTPMethod { .post }
            var path: String { "/login" }
            var contentType: ContentType { .formUrlEncoded }
            
            var headers: HTTPHeaders {
                var defaultHeaders = HTTPHeaders.default
                defaultHeaders.add(.contentType("\(contentType.rawValue); charset=UTF-8"))
                return defaultHeaders
            }
            
            init(username: String, password: String) {
                self.parameters = LoginParam(username: username, password: password)
            }
        }
        
        let mockSession = MockURLSession()
        let expectedUser = MockUser(id: 1, name: "Test User", email: "test@example.com")
        try mockSession.setMockJSON(expectedUser)
        
        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            session: mockSession
        )
        
        let result = try await client.request(FormLoginRequest(username: "test", password: "pass"))
        
        #expect(result == expectedUser)
        let contentType = mockSession.capturedRequest?.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(contentType.contains("x-www-form-urlencoded"))
        
        let bodyData = mockSession.capturedRequest?.httpBody ?? Data()
        let bodyString = String(data: bodyData, encoding: .utf8) ?? ""
        #expect(bodyString.contains("username=test"))
        #expect(bodyString.contains("password=pass"))
    }
}


@Suite("Request Interceptor Tests")
struct RequestInterceptorTests {

    final class MockRequestInterceptor: RequestInterceptor, @unchecked Sendable {
        var headerName: String
        var headerValue: String
        private(set) var callCount: Int = 0

        init(headerName: String, headerValue: String) {
            self.headerName = headerName
            self.headerValue = headerValue
        }

        func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
            callCount += 1
            var request = urlRequest
            request.setValue(headerValue, forHTTPHeaderField: headerName)
            return request
        }
    }

    struct InterceptedGetRequest: APIDefinition {
        typealias Parameter = EmptyParameter
        typealias APIResponse = MockUser

        var method: HTTPMethod { .get }
        var path: String { "/users/1" }

        let interceptors: [RequestInterceptor]

        var requestInterceptors: [RequestInterceptor] { interceptors }
    }

    @Test("Single request interceptor adds header")
    func singleInterceptorAddsHeader() async throws {
        let mockSession = MockURLSession()
        let expectedUser = MockUser(id: 1, name: "John", email: "john@example.com")
        try mockSession.setMockJSON(expectedUser)

        let authInterceptor = MockRequestInterceptor(headerName: "Authorization", headerValue: "Bearer token123")

        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            session: mockSession
        )

        let request = InterceptedGetRequest(interceptors: [authInterceptor])
        _ = try await client.request(request)

        #expect(authInterceptor.callCount == 1)
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer token123")
    }

    @Test("Multiple request interceptors are chained in order")
    func multipleInterceptorsChained() async throws {
        let mockSession = MockURLSession()
        let expectedUser = MockUser(id: 1, name: "John", email: "john@example.com")
        try mockSession.setMockJSON(expectedUser)

        let authInterceptor = MockRequestInterceptor(headerName: "Authorization", headerValue: "Bearer token")
        let trackingInterceptor = MockRequestInterceptor(headerName: "X-Request-ID", headerValue: "req-123")
        let customInterceptor = MockRequestInterceptor(headerName: "X-Custom", headerValue: "custom-value")

        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            session: mockSession
        )

        let request = InterceptedGetRequest(interceptors: [authInterceptor, trackingInterceptor, customInterceptor])
        _ = try await client.request(request)

        #expect(authInterceptor.callCount == 1)
        #expect(trackingInterceptor.callCount == 1)
        #expect(customInterceptor.callCount == 1)
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "X-Request-ID") == "req-123")
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "X-Custom") == "custom-value")
    }

    @Test("Interceptor can override previous header")
    func interceptorOverridesPreviousHeader() async throws {
        let mockSession = MockURLSession()
        let expectedUser = MockUser(id: 1, name: "John", email: "john@example.com")
        try mockSession.setMockJSON(expectedUser)

        let firstInterceptor = MockRequestInterceptor(headerName: "X-Token", headerValue: "first")
        let secondInterceptor = MockRequestInterceptor(headerName: "X-Token", headerValue: "second")

        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            session: mockSession
        )

        let request = InterceptedGetRequest(interceptors: [firstInterceptor, secondInterceptor])
        _ = try await client.request(request)

        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "X-Token") == "second")
    }

    @Test("Request interceptor throwing error stops the chain")
    func interceptorThrowingErrorStopsChain() async throws {
        struct ThrowingInterceptor: RequestInterceptor {
            func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
                throw NetworkError.undefined
            }
        }

        let mockSession = MockURLSession()
        let expectedUser = MockUser(id: 1, name: "John", email: "john@example.com")
        try mockSession.setMockJSON(expectedUser)

        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            session: mockSession
        )

        let request = InterceptedGetRequest(interceptors: [ThrowingInterceptor()])

        await #expect(throws: NetworkError.self) {
            try await client.request(request)
        }

        #expect(mockSession.requestCount == 0)
    }
}


@Suite("Response Interceptor Tests")
struct ResponseInterceptorTests {

    final class MockResponseInterceptor: ResponseInterceptor, @unchecked Sendable {
        private(set) var callCount: Int = 0
        private(set) var capturedResponse: Response?

        func adapt(_ urlResponse: Response, request: URLRequest) async throws -> Response {
            callCount += 1
            capturedResponse = urlResponse
            return urlResponse
        }
    }

    struct ResponseInterceptedRequest: APIDefinition {
        typealias Parameter = EmptyParameter
        typealias APIResponse = MockUser

        var method: HTTPMethod { .get }
        var path: String { "/users/1" }

        let interceptors: [ResponseInterceptor]

        var responseInterceptors: [ResponseInterceptor] { interceptors }
    }

    @Test("Response interceptor receives response")
    func responseInterceptorReceivesResponse() async throws {
        let mockSession = MockURLSession()
        let expectedUser = MockUser(id: 1, name: "John", email: "john@example.com")
        try mockSession.setMockJSON(expectedUser)

        let responseInterceptor = MockResponseInterceptor()

        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            session: mockSession
        )

        let request = ResponseInterceptedRequest(interceptors: [responseInterceptor])
        _ = try await client.request(request)

        #expect(responseInterceptor.callCount == 1)
        #expect(responseInterceptor.capturedResponse?.statusCode == 200)
    }

    @Test("Multiple response interceptors are chained")
    func multipleResponseInterceptorsChained() async throws {
        let mockSession = MockURLSession()
        let expectedUser = MockUser(id: 1, name: "John", email: "john@example.com")
        try mockSession.setMockJSON(expectedUser)

        let first = MockResponseInterceptor()
        let second = MockResponseInterceptor()

        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            session: mockSession
        )

        let request = ResponseInterceptedRequest(interceptors: [first, second])
        _ = try await client.request(request)

        #expect(first.callCount == 1)
        #expect(second.callCount == 1)
    }
}


@Suite("Retry Policy Tests")
struct RetryPolicyTests {

    struct TestRetryPolicy: RetryPolicy {
        let maxRetries: Int
        let retryDelay: TimeInterval

        func shouldRetry(error: NetworkError, attempt: Int) -> Bool {
            guard attempt < maxRetries else { return false }
            switch error {
            case .statusCode(let response):
                return [500, 502, 503, 504].contains(response.statusCode)
            default:
                return false
            }
        }
    }

    @Test("Retry succeeds after transient failures")
    func retrySucceedsAfterFailures() async throws {
        let mockSession = MockURLSession()
        let expectedUser = MockUser(id: 1, name: "John", email: "john@example.com")

        mockSession.failUntilAttempt = 2
        mockSession.failureStatusCode = 503
        mockSession.successData = try JSONEncoder().encode(expectedUser)

        let retryPolicy = TestRetryPolicy(maxRetries: 3, retryDelay: 0.01)
        let networkConfig = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            timeout: 30.0,
            cachePolicy: .useProtocolCachePolicy,
            retryPolicy: retryPolicy
        )

        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            networkConfiguration: networkConfig,
            session: mockSession
        )

        let result = try await client.request(SimpleGetRequest())

        #expect(result == expectedUser)
        #expect(mockSession.requestCount == 3)
    }

    @Test("Retry exhausts max retries and throws error")
    func retryExhaustsMaxRetries() async throws {
        let mockSession = MockURLSession()

        mockSession.failUntilAttempt = 10
        mockSession.failureStatusCode = 500

        let retryPolicy = TestRetryPolicy(maxRetries: 2, retryDelay: 0.01)
        let networkConfig = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            timeout: 30.0,
            cachePolicy: .useProtocolCachePolicy,
            retryPolicy: retryPolicy
        )

        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            networkConfiguration: networkConfig,
            session: mockSession
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(SimpleGetRequest())
        }

        #expect(mockSession.requestCount == 3)
    }

    @Test("No retry for non-retryable errors")
    func noRetryForNonRetryableErrors() async throws {
        let mockSession = MockURLSession()

        mockSession.failUntilAttempt = 10
        mockSession.failureStatusCode = 404

        let retryPolicy = TestRetryPolicy(maxRetries: 3, retryDelay: 0.01)
        let networkConfig = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            timeout: 30.0,
            cachePolicy: .useProtocolCachePolicy,
            retryPolicy: retryPolicy
        )

        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            networkConfiguration: networkConfig,
            session: mockSession
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(SimpleGetRequest())
        }

        #expect(mockSession.requestCount == 1)
    }

    @Test("No retry without retry policy")
    func noRetryWithoutPolicy() async throws {
        let mockSession = MockURLSession()

        mockSession.failUntilAttempt = 10
        mockSession.failureStatusCode = 500

        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            session: mockSession
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(SimpleGetRequest())
        }

        #expect(mockSession.requestCount == 1)
    }

    @Test("Retry policy correctly identifies retryable status codes")
    func retryPolicyIdentifiesRetryableCodes() {
        let policy = TestRetryPolicy(maxRetries: 3, retryDelay: 1.0)
        let response = Response(
            statusCode: 503,
            data: Data(),
            request: URLRequest(url: URL(string: "https://example.com")!),
            response: HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
        )

        #expect(policy.shouldRetry(error: .statusCode(response), attempt: 0) == true)
        #expect(policy.shouldRetry(error: .statusCode(response), attempt: 1) == true)
        #expect(policy.shouldRetry(error: .statusCode(response), attempt: 2) == true)
        #expect(policy.shouldRetry(error: .statusCode(response), attempt: 3) == false)
    }
}


@Suite("Multipart Form-Data Tests")
struct MultipartFormDataTests {
    
    @Test("Multipart form data encodes text fields correctly")
    func multipartTextFields() throws {
        var formData = MultipartFormData(boundary: "test-boundary")
        formData.append("John", name: "name")
        formData.append("john@example.com", name: "email")
        formData.append(25, name: "age")
        
        let data = formData.encode()
        let string = try #require(String(data: data, encoding: .utf8))
        
        #expect(string.contains("--test-boundary"))
        #expect(string.contains("name=\"name\""))
        #expect(string.contains("John"))
        #expect(string.contains("name=\"email\""))
        #expect(string.contains("john@example.com"))
        #expect(string.contains("name=\"age\""))
        #expect(string.contains("25"))
        #expect(string.contains("--test-boundary--"))
    }
    
    @Test("Multipart form data encodes file correctly")
    func multipartFileField() throws {
        var formData = MultipartFormData(boundary: "test-boundary")
        let imageData = "fake-image-content".data(using: .utf8)!
        formData.append(imageData, name: "avatar", fileName: "avatar.png", mimeType: "image/png")
        
        let data = formData.encode()
        let string = try #require(String(data: data, encoding: .utf8))
        
        #expect(string.contains("name=\"avatar\""))
        #expect(string.contains("filename=\"avatar.png\""))
        #expect(string.contains("Content-Type: image/png"))
        #expect(string.contains("fake-image-content"))
    }
    
    @Test("Multipart content type header includes boundary")
    func multipartContentTypeHeader() {
        let formData = MultipartFormData(boundary: "my-boundary-123")
        
        #expect(formData.contentTypeHeader == "multipart/form-data; boundary=my-boundary-123")
    }
    
    @Test("Multipart upload request works correctly")
    func multipartUploadRequest() async throws {
        struct UploadAvatarRequest: MultipartAPIDefinition {
            typealias APIResponse = MockUser
            
            var multipartFormData: MultipartFormData
            var method: HTTPMethod { .post }
            var path: String { "/upload" }
            
            init(imageData: Data, userId: Int) {
                var formData = MultipartFormData()
                formData.append(imageData, name: "file", fileName: "avatar.png", mimeType: "image/png")
                formData.append(userId, name: "userId")
                self.multipartFormData = formData
            }
        }
        
        let mockSession = MockURLSession()
        let expectedUser = MockUser(id: 1, name: "Test User", email: "test@example.com")
        try mockSession.setMockJSON(expectedUser)
        
        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            session: mockSession
        )
        
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let result = try await client.upload(UploadAvatarRequest(imageData: imageData, userId: 1))

        #expect(result == expectedUser)
        #expect(mockSession.capturedRequest?.httpMethod == "POST")
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)
        #expect(mockSession.capturedRequest?.httpBody != nil)
    }
}


@Suite("Logger Masking Options Tests")
struct LoggerMaskingOptionsTests {

    @Test("Default masking options includes common sensitive headers")
    func defaultMaskingOptionsIncludesSensitiveHeaders() {
        let options = LoggerMaskingOptions.default

        #expect(options.shouldMask(header: "Authorization") == true)
        #expect(options.shouldMask(header: "Cookie") == true)
        #expect(options.shouldMask(header: "X-API-Key") == true)
        #expect(options.shouldMask(header: "X-Auth-Token") == true)
        #expect(options.maskCookies == true)
    }

    @Test("None masking options disables all masking")
    func noneMaskingOptionsDisablesAll() {
        let options = LoggerMaskingOptions.none

        #expect(options.shouldMask(header: "Authorization") == false)
        #expect(options.shouldMask(header: "Cookie") == false)
        #expect(options.maskCookies == false)
        #expect(options.maskRequestBody == false)
        #expect(options.maskResponseBody == false)
    }

    @Test("Strict masking options masks everything")
    func strictMaskingOptionsMasksEverything() {
        let options = LoggerMaskingOptions.strict

        #expect(options.shouldMask(header: "Authorization") == true)
        #expect(options.maskCookies == true)
        #expect(options.maskRequestBody == true)
        #expect(options.maskResponseBody == true)
    }

    @Test("Header matching is case-insensitive")
    func headerMatchingIsCaseInsensitive() {
        let options = LoggerMaskingOptions.default

        #expect(options.shouldMask(header: "authorization") == true)
        #expect(options.shouldMask(header: "AUTHORIZATION") == true)
        #expect(options.shouldMask(header: "Authorization") == true)
        #expect(options.shouldMask(header: "x-api-key") == true)
        #expect(options.shouldMask(header: "X-API-KEY") == true)
    }

    @Test("Non-sensitive headers are not masked")
    func nonSensitiveHeadersNotMasked() {
        let options = LoggerMaskingOptions.default

        #expect(options.shouldMask(header: "Content-Type") == false)
        #expect(options.shouldMask(header: "Accept") == false)
        #expect(options.shouldMask(header: "User-Agent") == false)
        #expect(options.shouldMask(header: "X-Request-ID") == false)
    }

    @Test("maskHeaders replaces sensitive header values")
    func maskHeadersReplacesSensitiveValues() {
        let options = LoggerMaskingOptions.default

        let headers = [
            "Authorization": "Bearer secret-token",
            "Content-Type": "application/json",
            "X-API-Key": "api-key-12345",
            "Accept": "application/json"
        ]

        let masked = options.maskHeaders(headers)

        #expect(masked["Authorization"] == "[MASKED]")
        #expect(masked["X-API-Key"] == "[MASKED]")
        #expect(masked["Content-Type"] == "application/json")
        #expect(masked["Accept"] == "application/json")
    }

    @Test("Custom masking options can be created")
    func customMaskingOptions() {
        let options = LoggerMaskingOptions(
            sensitiveHeaders: ["X-Custom-Secret", "My-Token"],
            maskRequestBody: true,
            maskResponseBody: false,
            maskCookies: false,
            maskPlaceholder: "***REDACTED***"
        )

        #expect(options.shouldMask(header: "X-Custom-Secret") == true)
        #expect(options.shouldMask(header: "My-Token") == true)
        #expect(options.shouldMask(header: "Authorization") == false)
        #expect(options.maskRequestBody == true)
        #expect(options.maskResponseBody == false)
        #expect(options.maskPlaceholder == "***REDACTED***")
    }
}


@Suite("Task Cancellation Tests")
struct TaskCancellationTests {

    final class DelayedMockURLSession: URLSessionProtocol, @unchecked Sendable {
        var mockData: Data = Data()
        var mockResponse: URLResponse = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        var delay: UInt64 = 1_000_000_000

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try await Task.sleep(nanoseconds: delay)
            return (mockData, mockResponse)
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

    @Test("Cancelled task throws NetworkError.cancelled")
    func cancelledTaskThrowsCancelledError() async throws {
        let mockSession = DelayedMockURLSession()
        mockSession.delay = 5_000_000_000
        let expectedUser = MockUser(id: 1, name: "John", email: "john@example.com")
        try mockSession.setMockJSON(expectedUser)

        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            session: mockSession
        )

        let task = Task {
            try await client.request(SimpleGetRequest())
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected NetworkError.cancelled to be thrown")
        } catch let error as NetworkError {
            if case .cancelled = error {
                // Expected
            } else {
                Issue.record("Expected NetworkError.cancelled but got \(error)")
            }
        } catch is CancellationError {
            // Also acceptable
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("URLError.cancelled is converted to NetworkError.cancelled")
    func urlErrorCancelledConverted() async throws {
        let mockSession = MockURLSession()
        mockSession.mockError = URLError(.cancelled)

        let client = try DefaultNetworkClient(
            configuration: MockTestAPI(),
            session: mockSession
        )

        do {
            _ = try await client.request(SimpleGetRequest())
            Issue.record("Expected error to be thrown")
        } catch let error as NetworkError {
            if case .cancelled = error {
                // Expected
            } else {
                Issue.record("Expected NetworkError.cancelled but got \(error)")
            }
        }
    }

    @Test("NetworkError.isCancellation correctly identifies cancellation errors")
    func isCancellationIdentifiesErrors() {
        #expect(NetworkError.isCancellation(CancellationError()) == true)
        #expect(NetworkError.isCancellation(URLError(.cancelled)) == true)
        #expect(NetworkError.isCancellation(URLError(.timedOut)) == false)
        #expect(NetworkError.isCancellation(URLError(.notConnectedToInternet)) == false)
    }
}
