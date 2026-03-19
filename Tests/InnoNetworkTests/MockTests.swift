import Foundation
import Testing
@testable import InnoNetwork

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
        
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
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
        
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
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
        
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
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
        
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
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
        
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
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
        
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )
        
        _ = try await client.request(EmptyDeleteRequest())
    }
}


@Suite("Query Parameter Encoding Tests")
struct QueryParameterTests {
    
    @Test("Array parameters are encoded correctly")
    func arrayParameterEncoding() throws {
        struct ArrayParam: Encodable {
            let tags: [String]
        }
        
        let param = ArrayParam(tags: ["swift", "ios", "network"])
        let queryItems = try URLQueryEncoder().encode(param)
        
        #expect(queryItems.count == 3)
        #expect(queryItems.contains { $0.name == "tags[0]" && $0.value == "swift" })
        #expect(queryItems.contains { $0.name == "tags[1]" && $0.value == "ios" })
        #expect(queryItems.contains { $0.name == "tags[2]" && $0.value == "network" })
    }
    
    @Test("Nested object parameters are encoded correctly")
    func nestedObjectEncoding() throws {
        struct NestedParam: Encodable {
            struct Filter: Encodable {
                let minAge: Int
                let maxAge: Int
            }
            let filter: Filter
        }
        
        let param = NestedParam(filter: .init(minAge: 18, maxAge: 65))
        let queryItems = try URLQueryEncoder().encode(param)
        
        #expect(queryItems.contains { $0.name == "filter[minAge]" && $0.value == "18" })
        #expect(queryItems.contains { $0.name == "filter[maxAge]" && $0.value == "65" })
    }
    
    @Test("Boolean parameters are encoded as true/false")
    func booleanEncoding() throws {
        struct BoolParam: Encodable {
            let active: Bool
            let verified: Bool
        }
        
        let param = BoolParam(active: true, verified: false)
        let queryItems = try URLQueryEncoder().encode(param)
        
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
        let data = try URLQueryEncoder().encodeForm(param)
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
        
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
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
        
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
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
