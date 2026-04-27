import Foundation


/// Describes a long-lived streaming endpoint executed by
/// ``DefaultNetworkClient/stream(_:)``.
///
/// Streaming endpoints differ from ``APIDefinition`` in two ways:
///
/// 1. The transport is line-delimited bytes (Server-Sent Events, NDJSON,
///    `chunked` log feeds) rather than a single buffered body.
/// 2. The ``RetryPolicy`` is intentionally bypassed because mid-stream
///    retry semantics are application-specific — a partial event prefix
///    cannot be replayed transparently. Reconnect logic, when needed,
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

    /// Decode a single line (without trailing newline) into an `Output`,
    /// or return `nil` to skip it.
    ///
    /// - Parameter line: One line of UTF-8 text from the response stream.
    /// - Throws: Any error that should terminate the stream and surface
    ///   to the consumer.
    func decode(line: String) throws -> Output?
}


public extension StreamingAPIDefinition {
    var headers: HTTPHeaders { HTTPHeaders() }
    var requestInterceptors: [RequestInterceptor] { [] }
    var acceptableStatusCodes: Set<Int>? { nil }
}
