import Foundation

/// Controls how response bodies are collected before decode.
///
/// The same byte ceiling applies to inline requests and file-backed uploads.
/// Bounded file-upload responses require a streaming-capable session so the
/// limit can be enforced before the complete response is buffered.
public enum ResponseBodyBufferingPolicy: Sendable, Equatable {
    /// Prefer `URLSession.bytes(for:)` and collect into a `Data` buffer.
    ///
    /// When `maxBytes` is `nil`, a `URLSessionProtocol` implementation that
    /// reports streaming as unsupported with
    /// ``NetworkConfigurationFailureReason/invalidRequest(_:)`` falls back to
    /// the buffered `data(for:)` path. Bounded streaming (`maxBytes != nil`)
    /// does not fall back, because the buffered path cannot enforce the limit
    /// before the body is collected.
    case streaming(maxBytes: Int64?)
    /// Use `URLSession.data(for:)` for inline requests, preserving the pre-4.0
    /// buffered transport path while still applying the optional size limit.
    /// File-backed uploads with a non-`nil` limit still stream their response,
    /// because `URLSession.upload(for:fromFile:)` returns only after buffering
    /// the complete response.
    case buffered(maxBytes: Int64?)

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
