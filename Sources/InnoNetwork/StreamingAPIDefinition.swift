import Foundation

/// Resume policy for a ``StreamingAPIDefinition``.
///
/// Streaming requests bypass the configured ``RetryPolicy`` because a partial
/// event prefix cannot be replayed transparently. This policy describes the
/// narrow alternative: re-establish the connection after a transport-level
/// disconnect, using the most recent non-empty event id observed by the
/// client as a `Last-Event-ID` HTTP header so the server can resume from the
/// right position. Designed for Server-Sent Events but applicable to any
/// id-bearing line stream.
public enum StreamingResumePolicy: Sendable, Equatable {
    /// Do not resume after a mid-stream transport disconnect. The error is
    /// surfaced to the consumer as-is. This is the default.
    case disabled

    /// Resume up to `maxAttempts` times after a mid-stream transport
    /// disconnect. Between attempts, the client waits `retryDelay` seconds
    /// before reconnecting and attaches `Last-Event-ID: <last-seen-id>` to
    /// the new request when the cursor is non-empty. The last-seen id comes
    /// from the consumer's ``StreamingAPIDefinition/eventID(from:)`` hook.
    ///
    /// Resume is only triggered when an event id has been observed at least
    /// once during the current attempt. An empty id is treated as an explicit
    /// cursor reset: it clears any prior id and reconnects without a
    /// `Last-Event-ID` header. A malformed id disables resume for that
    /// attempt.
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

/// Marker protocol for streaming resume strategies introduced by the 4.0.0
/// line. The protocol gives future strategies (byte-offset replay, NDJSON
/// cursor windows, vendor-specific opaque tokens) a single extension
/// point so the streaming executor can interrogate compatibility without
/// pattern-matching the legacy ``StreamingResumePolicy`` enum.
///
/// In the 4.0.0 release the only conformer is ``StreamingResumePolicy``
/// itself; consumers should keep building the policy through that enum
/// and rely on the protocol surface for compatibility checks. The next
/// stage of the release wires the ``isCompatible(with:)`` decision into
/// `DefaultNetworkClient.stream(_:bufferingPolicy:)`, where a bounded
/// buffer paired with a non-disabled resume strategy is rejected before
/// the transport starts.
public protocol StreamingResumeStrategy: Sendable {
    /// Returns whether the strategy is compatible with the supplied
    /// buffering policy.
    ///
    /// A bounded buffering policy (``StreamingBufferingPolicy/bufferingNewest(_:)``
    /// or ``StreamingBufferingPolicy/bufferingOldest(_:)``) silently drops
    /// outputs when the consumer falls behind. Resume strategies that rely
    /// on contiguous client-side state — Last-Event-ID is the in-tree
    /// example — would silently lose events whose ids the dropped outputs
    /// carried. This method lets the executor refuse the mismatch instead.
    /// The disabled resume strategy returns `true` for every buffering
    /// policy because nothing on the client depends on the dropped
    /// frames.
    func isCompatible(with bufferingPolicy: StreamingBufferingPolicy) -> Bool
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

    /// Whether the policy may drop already-produced outputs when the
    /// consumer falls behind. Only ``unbounded`` returns `false`; every
    /// other case is allowed to discard frames to enforce the limit.
    public var maySilentlyDropOutputs: Bool {
        switch self {
        case .unbounded:
            return false
        case .bufferingNewest, .bufferingOldest:
            return true
        }
    }
}

extension StreamingResumePolicy: StreamingResumeStrategy {
    public func isCompatible(with bufferingPolicy: StreamingBufferingPolicy) -> Bool {
        switch self {
        case .disabled:
            // The consumer has opted out of resume entirely, so a bounded
            // buffer cannot mask lost recovery state.
            return true
        case .lastEventID:
            // Last-Event-ID resume re-issues against the most recent id the
            // consumer has actually observed. A bounded buffer can drop a
            // not-yet-consumed frame that carried the next id, so the
            // server would replay over the gap — bounded + lastEventID is
            // unsafe.
            return !bufferingPolicy.maySilentlyDropOutputs
        }
    }
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
    /// Authentication scope required by this stream.
    ///
    /// The default ``PublicAuthScope`` preserves the 4.x source-compatible
    /// behaviour for existing streams. Streams that require bearer-token
    /// attachment should declare `typealias Auth = AuthRequiredScope`; the
    /// executor then validates that the client was configured with
    /// ``RefreshTokenPolicy`` before opening the transport.
    associatedtype Auth: AuthScope = PublicAuthScope

    var method: HTTPMethod { get }
    var path: String { get }
    var headers: HTTPHeaders { get }
    var requestInterceptors: [RequestInterceptor] { get }
    var requestSigners: [RequestSigner] { get }

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
    /// resume attempts. An empty string clears the previous cursor and is not
    /// sent as a blank header. Values containing characters unsafe for HTTP
    /// headers disable resume for that attempt. Default returns `nil`, which
    /// disables resume even if ``resumePolicy`` is configured.
    func eventID(from output: Output) -> String?
}


public extension StreamingAPIDefinition {
    var headers: HTTPHeaders { HTTPHeaders() }
    var requestInterceptors: [RequestInterceptor] { [] }
    var requestSigners: [RequestSigner] { [] }
    var acceptableStatusCodes: Set<Int>? { nil }
    var resumePolicy: StreamingResumePolicy { .disabled }
    func eventID(from output: Output) -> String? { nil }
}
