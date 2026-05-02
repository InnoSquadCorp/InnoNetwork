import Foundation

/// Controls how inline response bodies are collected before decode.
public enum ResponseBodyBufferingPolicy: Sendable, Equatable {
    /// Prefer `URLSession.bytes(for:)` and collect into a bounded `Data`
    /// buffer. This is the 4.0.0 default for inline requests.
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
