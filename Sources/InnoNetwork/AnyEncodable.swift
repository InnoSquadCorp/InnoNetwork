import Foundation

/// Type-erased `Encodable` wrapper used by the builder-style ``Endpoint`` API
/// to carry an arbitrary request body without forcing every endpoint type
/// to surface its parameter shape as a generic parameter.
///
/// `AnyEncodable` captures the wrapped value's `encode(to:)` behaviour in a
/// `@Sendable` closure so the wrapper itself can travel across actor and
/// task boundaries while preserving Swift 6 strict concurrency.
public struct AnyEncodable: Encodable, Sendable {
    private let _encode: @Sendable (Encoder) throws -> Void

    public init(_ wrapped: some Encodable & Sendable) {
        self._encode = { encoder in
            try wrapped.encode(to: encoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
