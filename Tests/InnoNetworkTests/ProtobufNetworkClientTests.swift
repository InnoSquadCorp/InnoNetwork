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


// Mock URLSession for protobuf testing
final class MockProtobufURLSession: URLSessionProtocol, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        // Create mock response
        let response = TestUserResponse(userID: 1, name: "Test User", email: "test@example.com")
        let data = try response.serializedData()

        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/x-protobuf"]
        )!

        return (data, httpResponse)
    }
}


@Suite
struct ProtobufNetworkClientTests {
    @Test func protobufRequestSuccess() async throws {
        let mockSession = MockProtobufURLSession()
        let client = try DefaultNetworkClient(
            configuration: TestAPIConfiguration(),
            session: mockSession
        )

        let response = try await client.protobufRequest(GetUserProtobuf(userID: 1))
        #expect(response.userID == 1)
        #expect(response.name == "Test User")
        #expect(response.email == "test@example.com")
    }

    @Test func protobufSerializationTest() throws {
        // Test protobuf message serialization
        let request = TestUserRequest(userID: 42)
        let data = try request.serializedData()
        #expect(!data.isEmpty)

        // Test deserialization
        let decoded = try TestUserRequest(serializedData: data)
        #expect(decoded.userID == 42)
    }
}


struct TestAPIConfiguration: APIConfigure {
    var host: String { "https://test.example.com" }
    var basePath: String { "" }
}
