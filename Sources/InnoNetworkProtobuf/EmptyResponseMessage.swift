import InnoNetwork
import SwiftProtobuf


/// Marks a protobuf response type that can be synthesized from an empty HTTP body.
public protocol HTTPEmptyResponseMessage: SwiftProtobuf.Message & Sendable {
    static func emptyResponseValue() -> Self
}
