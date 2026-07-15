import Foundation
import InnoNetwork

/// Minimal operation shape generated OpenAPI clients can adapt into InnoNetwork.
public protocol OpenAPIRestOperation: Sendable {
    /// Request parameter type, if the operation has encodable input.
    associatedtype Parameters: Encodable & Sendable = EmptyParameter
    /// Decoded response type.
    associatedtype Response: Decodable & Sendable

    /// HTTP method used by the operation.
    var method: HTTPMethod { get }
    /// Path relative to the configured base URL.
    var path: String { get }
    /// Session bearer-authentication policy for this operation.
    var sessionAuthentication: SessionAuthentication { get }
    /// Additional request headers.
    var headers: HTTPHeaders { get }
    /// Encodable request parameters, or `nil` when the operation has no input.
    var parameters: Parameters? { get }
    /// Endpoint-specific status-code override.
    var acceptableStatusCodes: Set<Int>? { get }
    /// InnoNetwork transport policy used to encode and decode the operation.
    var transport: TransportPolicy<Response> { get }
}


public extension OpenAPIRestOperation {
    /// Default empty header set.
    var headers: HTTPHeaders { HTTPHeaders.default }
    /// Default parameter-less operation.
    var parameters: Parameters? { nil }
    /// Default session-level status-code handling.
    var acceptableStatusCodes: Set<Int>? { nil }

    /// Default method-aware transport: query for methods such as GET and HEAD
    /// whose parameters conventionally belong in the URL, JSON otherwise.
    var transport: TransportPolicy<Response> {
        method.defaultsToQueryTransport ? .query() : .json()
    }
}


/// APIDefinition wrapper for an OpenAPI operation descriptor.
public struct OpenAPIRequest<Operation: OpenAPIRestOperation>: APIDefinition {
    public typealias Parameter = Operation.Parameters
    public typealias APIResponse = Operation.Response

    private let operation: Operation

    /// Wraps an OpenAPI-style operation as an InnoNetwork request definition.
    public init(_ operation: Operation) {
        self.operation = operation
    }

    /// HTTP method forwarded from the operation.
    public var method: HTTPMethod { operation.method }
    /// Path forwarded from the operation.
    public var path: String { operation.path }
    /// Authentication policy forwarded from the operation.
    public var sessionAuthentication: SessionAuthentication { operation.sessionAuthentication }
    /// Headers forwarded from the operation.
    public var headers: HTTPHeaders { operation.headers }
    /// Parameters forwarded from the operation.
    public var parameters: Operation.Parameters? { operation.parameters }
    /// Status-code override forwarded from the operation.
    public var acceptableStatusCodes: Set<Int>? { operation.acceptableStatusCodes }
    /// Transport policy forwarded from the operation.
    public var transport: TransportPolicy<Operation.Response> { operation.transport }
}
