import Foundation
import InnoNetwork
import SwiftProtobuf


/// An empty protobuf response type for endpoints that return no data.
public struct ProtobufEmptyResponse: HTTPEmptyResponseMessage {
    public var unknownFields = SwiftProtobuf.UnknownStorage()

    public init() {}

    public static func emptyResponseValue() -> Self {
        Self()
    }

    public static let protoMessageName: String = "ProtobufEmptyResponse"

    public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
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
