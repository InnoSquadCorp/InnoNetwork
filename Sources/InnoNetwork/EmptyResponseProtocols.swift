import Foundation
import SwiftProtobuf


/// Marks a decodable response type that can be synthesized from an empty HTTP body.
public protocol HTTPEmptyResponseDecodable: Decodable & Sendable {
    static func emptyResponseValue() -> Self
}

/// Marks a protobuf response type that can be synthesized from an empty HTTP body.
public protocol HTTPEmptyResponseMessage: SwiftProtobuf.Message & Sendable {
    static func emptyResponseValue() -> Self
}
