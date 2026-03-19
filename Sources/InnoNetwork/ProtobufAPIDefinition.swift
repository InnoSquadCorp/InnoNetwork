import Foundation
import SwiftProtobuf


/// A protocol for defining API requests that use Protocol Buffers for serialization.
///
/// `ProtobufAPIDefinition` provides a type-safe way to define API requests where both
/// request parameters and responses are Protocol Buffer messages. The protocol handles
/// automatic serialization and deserialization of protobuf messages.
///
/// ## Usage
///
/// ```swift
/// struct GetUserRequest: ProtobufAPIDefinition {
///     typealias Parameter = UserRequestProto
///     typealias APIResponse = UserResponseProto
///
///     var method: HTTPMethod { .post }
///     var path: String { "/user" }
///     let parameters: UserRequestProto?
///
///     init(userID: Int32) {
///         self.parameters = UserRequestProto(userID: userID)
///     }
/// }
/// ```
///
/// ## Important Limitations
///
/// - **GET Requests**: GET requests with protobuf parameters are not supported because
///   binary protobuf data cannot be serialized to URL query parameters. For GET requests,
///   set `parameters` to `nil` or use path parameters in the `path` property.
/// - **Content Type**: All protobuf requests use `application/x-protobuf` content type.
/// - **Empty Responses**: For endpoints that return no data (204 No Content), use
///   `ProtobufEmptyResponse` as the `APIResponse` type.
///
/// ## Associated Types
///
/// - `Parameter`: The protobuf message type for request body (must conform to `SwiftProtobuf.Message`)
/// - `APIResponse`: The protobuf message type for response body (must conform to `SwiftProtobuf.Message`)
public protocol ProtobufAPIDefinition: Sendable {
    associatedtype Parameter: SwiftProtobuf.Message & Sendable
    associatedtype APIResponse: SwiftProtobuf.Message & Sendable

    var parameters: Parameter? { get }
    var method: HTTPMethod { get }
    var path: String { get }
    var responseDecoder: AnyResponseDecoder<APIResponse> { get }

    var headers: HTTPHeaders { get }

    var logger: NetworkLogger { get }
    var requestInterceptors: [RequestInterceptor] { get }
    var responseInterceptors: [ResponseInterceptor] { get }
}

extension ProtobufAPIDefinition {
    var transportPolicy: TransportPolicy<APIResponse> {
        TransportPolicy(
            requestEncoding: requestEncodingPolicy,
            responseDecoding: responseDecodingStrategy,
            responseDecoder: responseDecoder
        )
    }

    var requestEncodingPolicy: RequestEncodingPolicy { .protobuf }

    var responseDecodingStrategy: ResponseDecodingStrategy<APIResponse> {
        .protobuf
    }
}

public extension ProtobufAPIDefinition {
    var responseDecoder: AnyResponseDecoder<APIResponse> { AnyResponseDecoder(strategy: responseDecodingStrategy) }

    var headers: HTTPHeaders {
        var defaultHeaders = HTTPHeaders.default
        defaultHeaders.add(.contentType(ContentType.protobuf.rawValue))
        return defaultHeaders
    }

    var logger: NetworkLogger { DefaultNetworkLogger() }

    var requestInterceptors: [RequestInterceptor] { [] }

    var responseInterceptors: [ResponseInterceptor] { [] }
}

extension ProtobufAPIDefinition where APIResponse: HTTPEmptyResponseMessage {
    var responseDecodingStrategy: ResponseDecodingStrategy<APIResponse> { .protobufAllowingEmpty }
}

public extension ProtobufAPIDefinition where APIResponse: HTTPEmptyResponseMessage {
    var responseDecoder: AnyResponseDecoder<APIResponse> { AnyResponseDecoder(strategy: responseDecodingStrategy) }
}
