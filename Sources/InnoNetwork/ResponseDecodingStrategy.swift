import Foundation

package enum ResponseDecodingStrategy<Output: Sendable>: Sendable {
    case json(JSONDecoder)
    case jsonAllowingEmpty(JSONDecoder)
    case custom(@Sendable (Data, Response) throws -> Output)
}
