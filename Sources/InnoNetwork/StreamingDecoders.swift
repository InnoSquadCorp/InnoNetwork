import Foundation
import os

/// A single Server-Sent Events frame as defined by the WHATWG HTML Living
/// Standard.
///
/// Fields populate from `id:`, `event:`, and `data:` lines. Multiple
/// `data:` lines within one frame are joined with `\n`. The `retry:`
/// field carries the server-suggested reconnect delay in milliseconds
/// when present; consumers are free to honor or ignore it.
public struct ServerSentEvent: Sendable, Equatable {
    public var id: String?
    public var event: String?
    public var data: String
    public var retry: Int?

    public init(
        id: String? = nil,
        event: String? = nil,
        data: String = "",
        retry: Int? = nil
    ) {
        self.id = id
        self.event = event
        self.data = data
        self.retry = retry
    }
}


/// Stateful decoder that turns a stream of UTF-8 lines into a stream of
/// ``ServerSentEvent`` values.
///
/// Wire one of these into a ``StreamingAPIDefinition`` to consume an SSE
/// endpoint:
///
/// ```swift
/// final class MyEventStream: StreamingAPIDefinition {
///     typealias Output = ServerSentEvent
///
///     var method: HTTPMethod { .get }
///     var path: String { "/events" }
///     var headers: HTTPHeaders {
///         HTTPHeaders([HTTPHeader(name: "Accept", value: "text/event-stream")])
///     }
///
///     private let decoder = ServerSentEventDecoder()
///
///     func decode(line: String) throws -> ServerSentEvent? {
///         decoder.decode(line: line)
///     }
/// }
/// ```
///
/// Returning the decoder via a `let` member is enough — the decoder
/// guards its internal frame buffer with an `OSAllocatedUnfairLock` so
/// it is `Sendable` even when shared.
public final class ServerSentEventDecoder: Sendable {
    private struct State {
        var current = ServerSentEvent()
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    public init() {}

    /// Process one line (without trailing `\n`). Returns a fully-formed
    /// ``ServerSentEvent`` when a blank dispatch line completes the
    /// current frame, otherwise `nil`.
    ///
    /// - Parameter line: One UTF-8 line from the SSE response stream.
    /// - Returns: A dispatched event, or `nil` while still aggregating
    ///   the current frame.
    public func decode(line: String) -> ServerSentEvent? {
        state.withLock { state in
            // Blank line dispatches the current event.
            if line.isEmpty {
                let frame = state.current
                state.current = ServerSentEvent()
                if frame.id == nil, frame.event == nil, frame.data.isEmpty, frame.retry == nil {
                    return nil
                }
                var dispatched = frame
                // SSE spec: strip a single trailing newline appended by
                // the data-line aggregator above, since that newline was
                // a separator, not user content.
                if dispatched.data.hasSuffix("\n") {
                    dispatched.data.removeLast()
                }
                return dispatched
            }

            // Lines starting with ":" are comments per spec.
            if line.hasPrefix(":") {
                return nil
            }

            let field: String
            let value: String
            if let colon = line.firstIndex(of: ":") {
                field = String(line[..<colon])
                var rest = line[line.index(after: colon)...]
                if rest.hasPrefix(" ") {
                    rest = rest.dropFirst()
                }
                value = String(rest)
            } else {
                field = line
                value = ""
            }

            switch field {
            case "id":
                state.current.id = value
            case "event":
                state.current.event = value
            case "data":
                if !state.current.data.isEmpty {
                    state.current.data.append("\n")
                }
                state.current.data.append(value)
            case "retry":
                if let ms = Int(value) {
                    state.current.retry = ms
                }
            default:
                // Unknown fields are ignored per spec.
                break
            }
            return nil
        }
    }
}
