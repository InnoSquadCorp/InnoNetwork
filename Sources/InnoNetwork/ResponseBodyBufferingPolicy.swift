import Foundation

/// Controls how inline response bodies are collected before decode.
public enum ResponseBodyBufferingPolicy: Sendable, Equatable {
    /// Prefer `URLSession.bytes(for:)` and collect into a `Data` buffer.
    ///
    /// When `maxBytes` is `nil`, a `URLSessionProtocol` implementation that
    /// reports streaming as unsupported with
    /// ``NetworkConfigurationFailureReason/invalidRequest(_:)`` falls back to
    /// the buffered `data(for:)` path. Bounded streaming (`maxBytes != nil`)
    /// does not fall back, because the buffered path cannot enforce the limit
    /// before the body is collected.
    case streaming(maxBytes: Int64? = nil)
    /// Use `URLSession.data(for:)`, preserving the pre-4.0 buffered
    /// transport path while still applying the optional size limit.
    case buffered(maxBytes: Int64? = nil)

    package var maxBytes: Int64? {
        switch self {
        case .streaming(let maxBytes), .buffered(let maxBytes):
            return maxBytes.map { max(0, $0) }
        }
    }

    package func replacingMaxBytes(_ maxBytes: Int64?) -> ResponseBodyBufferingPolicy {
        let normalized = maxBytes.map { max(0, $0) }
        switch self {
        case .streaming:
            return .streaming(maxBytes: normalized)
        case .buffered:
            return .buffered(maxBytes: normalized)
        }
    }
}
