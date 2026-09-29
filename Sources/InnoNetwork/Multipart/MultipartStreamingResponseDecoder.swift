import Foundation

/// Event emitted by ``MultipartStreamingResponseDecoder``.
public enum MultipartStreamingEvent: Sendable, Equatable {
    /// A new part began after its headers were parsed.
    case partStarted(headers: [String: String])
    /// Body bytes for the current part. Large parts may produce many chunks.
    case bodyChunk(Data)
    /// The current part ended immediately before the next boundary delimiter.
    case partEnded
}

/// Streaming decoder for `multipart/*` response bodies.
///
/// Delimiters are recognized only at line starts. Optional SP/HTAB transport
/// padding, empty header blocks and LF-only peers are supported. Headers and
/// delimiter padding are each limited to 1 MiB; boundaries to 70 UTF-8 bytes.
public struct MultipartStreamingResponseDecoder: Sendable {
    private let boundaryOverride: String?

    /// Creates a decoder, optionally overriding the Content-Type boundary.
    public init(boundary: String? = nil) { self.boundaryOverride = boundary }

    /// Decodes chunked data into an unbounded event stream for compatibility.
    /// For large responses or slow consumers, use the awaited `receive`
    /// overload instead: this stream does not backpressure its producer.
    public func decode<Chunks: AsyncSequence>(
        _ chunks: Chunks, contentType: String
    ) -> AsyncThrowingStream<MultipartStreamingEvent, Error> where Chunks: Sendable, Chunks.Element == Data {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await decode(chunks, contentType: contentType) { event in
                        if case .terminated = continuation.yield(event) { throw CancellationError() }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Decodes with lossless backpressure: each callback completes before the
    /// next event is parsed or another upstream chunk is requested.
    ///
    /// No producer task or event queue is created. The parser processes input
    /// in 16 KiB slices and retains at most its 1 MiB header/padding limit plus
    /// one slice and boundary lookahead. The current upstream Data and memory
    /// retained by the caller or callback are outside this bound. Cancellation,
    /// upstream errors and callback errors propagate to the caller. Callbacks
    /// and upstream iterators must cooperate with cancellation.
    /// A closing MIME delimiter ends part delivery, not transport validation:
    /// epilogue bytes are discarded while input is drained to EOF. Late upstream
    /// errors still propagate; apply a transport deadline to unbounded inputs.
    /// - Parameters:
    ///   - chunks: Ordered response body bytes.
    ///   - contentType: Content-Type containing the boundary, unless overridden.
    ///   - receive: Awaited consumer for every ordered event; no events are dropped.
    public func decode<Chunks: AsyncSequence>(
        _ chunks: Chunks, contentType: String,
        receive: @Sendable (MultipartStreamingEvent) async throws -> Void
    ) async throws where Chunks: Sendable, Chunks.Element == Data {
        try Task.checkCancellation()
        var parser = try MultipartResponseParser(
            boundary: boundaryOverride ?? MultipartResponseParser.boundary(from: contentType))
        for try await chunk in chunks {
            try Task.checkCancellation()
            var offset = chunk.startIndex
            while offset < chunk.endIndex {
                try Task.checkCancellation()
                let end = min(chunk.endIndex, offset + MultipartResponseParser.sliceBytes)
                parser.append(Data(chunk[offset..<end]))
                while let event = try parser.next() {
                    try Task.checkCancellation()
                    try await receive(event)
                }
                offset = end
            }
        }
        try Task.checkCancellation()
        while let event = try parser.next(isFinal: true) {
            try Task.checkCancellation()
            try await receive(event)
        }
        try Task.checkCancellation()
    }
}
