import Foundation
import SwiftProtobuf


public protocol ProtobufAPIDefinition: Sendable {
    associatedtype Parameter: SwiftProtobuf.Message & Sendable
    associatedtype APIResponse: SwiftProtobuf.Message & Sendable

    var parameters: Parameter? { get }
    var method: HTTPMethod { get }
    var path: String { get }

    var headers: HTTPHeaders { get }

    var logger: NetworkLogger { get }
    var requestInterceptors: [RequestInterceptor] { get }
    var responseInterceptors: [ResponseInterceptor] { get }
}


extension ProtobufAPIDefinition where Parameter == EmptyParameter {
    public var parameters: Parameter? { nil }
}


public extension ProtobufAPIDefinition {
    var headers: HTTPHeaders {
        var defaultHeaders = HTTPHeaders.default
        defaultHeaders.add(.contentType("application/x-protobuf"))
        return defaultHeaders
    }

    var logger: NetworkLogger { DefaultNetworkLogger() }

    var requestInterceptors: [RequestInterceptor] { [] }

    var responseInterceptors: [ResponseInterceptor] { [] }
}
