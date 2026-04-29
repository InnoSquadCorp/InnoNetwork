import Foundation

/// Marks a decodable response type that can be synthesized from an empty HTTP body.
public protocol HTTPEmptyResponseDecodable: Decodable & Sendable {
    static func emptyResponseValue() -> Self
}
