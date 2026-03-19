import Foundation

package enum ResponseDecodingStrategy<Output: Sendable>: Sendable {
    case json(JSONDecoder)
    case jsonAllowingEmpty(JSONDecoder)
    case protobuf
    case protobufAllowingEmpty
    case custom(@Sendable (Data, Response) throws -> Output)
}
