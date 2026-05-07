import Foundation

/// Resume policy for a ``StreamingAPIDefinition``.
///
/// Streaming requests bypass the configured ``RetryPolicy`` because a partial
/// event prefix cannot be replayed transparently. This policy describes the
/// narrow alternative: re-establish the connection after a transport-level
/// disconnect, using the most recent event id observed by the client as a
/// `Last-Event-ID` HTTP header so the server can resume from the right
/// position. Designed for Server-Sent Events but applicable to any
/// id-bearing line stream.
public enum StreamingResumePolicy: Sendable, Equatable {
    /// Do not resume after a mid-stream transport disconnect. The error is
    /// surfaced to the consumer as-is. This is the default.
    case disabled

    /// Resume up to `maxAttempts` times after a mid-stream transport
    /// disconnect. Between attempts, the client waits `retryDelay` seconds
    /// before reconnecting and attaches `Last-Event-ID: <last-seen-id>` to
    /// the new request. The last-seen id comes from the consumer's
    /// ``StreamingAPIDefinition/eventID(from:)`` hook.
    ///
    /// Resume is only triggered when an event id has been observed at least
    /// once during the current attempt — re-issuing without an id would
    /// cause the server to replay the entire stream.
    case lastEventID(maxAttempts: Int, retryDelay: TimeInterval = 1.0)

    /// Internal accessor used by the streaming executor.
    var maxAttempts: Int {
        switch self {
        case .disabled: return 0
        case .lastEventID(let maxAttempts, _): return max(0, maxAttempts)
        }
    }

    var retryDelay: TimeInterval {
        switch self {
        case .disabled: return 0
        case .lastEventID(_, let delay): return max(0, delay)
        }
    }
}

/// Output buffering policy for ``DefaultNetworkClient/stream(_:bufferingPolicy:)``.
///
/// The default streaming API uses ``unbounded`` so server-emitted frames are
/// never silently dropped by InnoNetwork. Long-lived high-volume streams can
/// opt into a bounded policy when the consumer prefers capped memory over
/// lossless delivery. Bounded policies rely on Swift's `AsyncThrowingStream`
/// buffering semantics and do not slow the underlying `URLSession` producer.
public enum StreamingBufferingPolicy: Sendable, Equatable {
    /// Preserve every decoded output until the consumer reads it.
    case unbounded
    /// Keep the newest `limit` outputs when the consumer falls behind.
    case bufferingNewest(Int)
    /// Keep the oldest `limit` outputs when the consumer falls behind.
    case bufferingOldest(Int)
}


/// Describes a long-lived streaming endpoint executed by
/// ``DefaultNetworkClient/stream(_:)``.
///
/// Streaming endpoints differ from ``APIDefinition`` in two ways:
///
/// 1. The transport is line-delimited bytes (Server-Sent Events, NDJSON,
///    `chunked` log feeds) rather than a single buffered body.
/// 2. The ``RetryPolicy`` is intentionally bypassed because mid-stream
///    retry semantics are application-specific — a partial event prefix
///    cannot be replayed transparently. Use ``resumePolicy`` for the
///    narrow Last-Event-ID-based resume behavior; deeper reconnect logic
///    belongs in the consumer.
///
/// Each line yielded by the transport is passed to ``decode(line:)``.
/// Returning `nil` skips the line (useful for SSE comment lines, blank
/// keep-alives, or NDJSON heartbeat strings); throwing terminates the
/// stream and surfaces the error to the consumer.
public protocol StreamingAPIDefinition: Sendable {
    associatedtype Output: Sendable

    var method: HTTPMethod { get }
    var path: String { get }
    var headers: HTTPHeaders { get }
    var requestInterceptors: [RequestInterceptor] { get }

    /// Per-endpoint override for the set of acceptable HTTP status codes used
    /// when validating the streaming response handshake. When `nil`, falls
    /// back to ``NetworkConfiguration/acceptableStatusCodes``.
    var acceptableStatusCodes: Set<Int>? { get }

    /// Resume policy applied when a mid-stream transport disconnect occurs.
    /// Default is ``StreamingResumePolicy/disabled``.
    var resumePolicy: StreamingResumePolicy { get }

    /// Decode a single line (without trailing newline) into an `Output`,
    /// or return `nil` to skip it.
    ///
    /// - Parameter line: One line of UTF-8 text from the response stream.
    /// - Throws: Any error that should terminate the stream and surface
    ///   to the consumer.
    func decode(line: String) throws -> Output?

    /// Returns the Last-Event-ID-style identifier for a decoded event, when
    /// the underlying protocol carries one. The library tracks the most
    /// recent non-nil result and uses it as the `Last-Event-ID` header on
    /// resume attempts. Default returns `nil`, which disables resume even if
    /// ``resumePolicy`` is configured.
    func eventID(from output: Output) -> String?
}


public extension StreamingAPIDefinition {
    var headers: HTTPHeaders { HTTPHeaders() }
    var requestInterceptors: [RequestInterceptor] { [] }
    var acceptableStatusCodes: Set<Int>? { nil }
    var resumePolicy: StreamingResumePolicy { .disabled }
    func eventID(from output: Output) -> String? { nil }
}
