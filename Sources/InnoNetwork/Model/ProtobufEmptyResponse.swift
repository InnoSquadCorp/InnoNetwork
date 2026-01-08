//
//  ProtobufEmptyResponse.swift
//  InnoNetwork
//
//  Created by Claude on 2026-01-08.
//

import Foundation
import SwiftProtobuf


/// An empty protobuf response type for endpoints that return no data.
///
/// Use this type as the `APIResponse` for `ProtobufAPIDefinition` when
/// the endpoint returns no response body (e.g., 204 No Content).
///
/// ## Example
///
/// ```swift
/// struct DeleteUser: ProtobufAPIDefinition {
///     typealias Parameter = UserRequest
///     typealias APIResponse = ProtobufEmptyResponse
///
///     var method: HTTPMethod { .delete }
///     var path: String { "/user/\(userID)" }
///     let parameters: UserRequest? = nil
///     let userID: Int
/// }
/// ```
public struct ProtobufEmptyResponse: SwiftProtobuf.Message, Sendable {
    public var unknownFields = SwiftProtobuf.UnknownStorage()

    public init() {}

    public static let protoMessageName: String = "ProtobufEmptyResponse"

    public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        // Empty message, nothing to decode
        while try decoder.nextFieldNumber() != nil {}
    }

    public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        try unknownFields.traverse(visitor: &visitor)
    }

    public func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard message is ProtobufEmptyResponse else { return false }
        return true
    }
}
