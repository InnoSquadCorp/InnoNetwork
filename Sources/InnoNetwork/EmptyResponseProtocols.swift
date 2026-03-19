import Foundation
import SwiftProtobuf


public protocol HTTPEmptyResponseDecodable: Decodable & Sendable {
    static func emptyResponseValue() -> Self
}

public protocol HTTPEmptyResponseMessage: SwiftProtobuf.Message & Sendable {
    static func emptyResponseValue() -> Self
}
