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
/// The decoder recognizes boundary delimiters only when they appear as
/// delimiter lines (`--boundary` or `--boundary--`) at the start of the body
/// or after a line break. Boundary-like bytes inside part payloads are emitted
/// as body chunks.
public struct MultipartStreamingResponseDecoder: Sendable {
    private let boundaryOverride: String?

    /// Creates a streaming multipart decoder.
    ///
    /// - Parameter boundary: Optional boundary override. When `nil`, the decoder
    ///   reads the boundary from the `Content-Type` passed to ``decode(_:contentType:)``.
    public init(boundary: String? = nil) {
        self.boundaryOverride = boundary
    }

    /// Decode a multipart response from chunked body data.
    public func decode<Chunks: AsyncSequence>(
        _ chunks: Chunks,
        contentType: String
    ) -> AsyncThrowingStream<MultipartStreamingEvent, Error> where Chunks: Sendable, Chunks.Element == Data {
        AsyncThrowingStream { continuation in
            let boundaryOverride = boundaryOverride
            let task = Task {
                do {
                    guard let boundary = boundaryOverride ?? Self.boundary(from: contentType), !boundary.isEmpty else {
                        throw NetworkError.configuration(reason: .invalidRequest("Missing multipart boundary."))
                    }

                    var parser = MultipartStreamingParser(boundary: boundary)
                    for try await chunk in chunks {
                        try parser.feed(chunk) { event in
                            continuation.yield(event)
                        }
                    }
                    try parser.finish { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private static func boundary(from contentType: String) -> String? {
        contentType
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.lowercased().hasPrefix("boundary=") }
            .map { String($0.dropFirst("boundary=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    }
}


private extension Data {
    var headerSeparatorRange: Range<Data.Index>? {
        range(of: Data("\r\n\r\n".utf8)) ?? range(of: Data("\n\n".utf8))
    }

    func hasPrefix(_ prefix: Data, at index: Data.Index) -> Bool {
        guard index <= endIndex, distance(from: index, to: endIndex) >= prefix.count else {
            return false
        }
        return self[index..<self.index(index, offsetBy: prefix.count)] == prefix
    }
}


private func trimTrailingLineBreak(in data: Data, end: inout Data.Index) {
    guard end > data.startIndex else { return }
    let previous = data.index(before: end)
    if data[previous] == UInt8(ascii: "\n") {
        end = previous
        if end > data.startIndex {
            let carriageReturn = data.index(before: end)
            if data[carriageReturn] == UInt8(ascii: "\r") {
                end = carriageReturn
            }
        }
    }
}


private struct MultipartStreamingParser {
    private enum State {
        case seekingFirstBoundary
        case readingHeaders
        case readingBody
        case finished
    }

    /// Hard upper bound on per-part header bytes the decoder will buffer
    /// before the closing `\r\n\r\n` delimiter. Real-world multipart parts
    /// have headers measured in hundreds of bytes; 1 MiB is a generous
    /// safety net against malformed or hostile peers that never close the
    /// header block, which would otherwise grow `buffer` without bound.
    static let maxPartHeaderBytes = 1 * 1024 * 1024

    private let delimiter: Data
    private var buffer = Data()
    private var state: State = .seekingFirstBoundary

    init(boundary: String) {
        self.delimiter = Data("--\(boundary)".utf8)
    }

    mutating func feed(
        _ chunk: Data,
        emit: (MultipartStreamingEvent) -> Void
    ) throws {
        buffer.append(chunk)
        try process(emit: emit)
    }

    mutating func finish(
        emit: (MultipartStreamingEvent) -> Void
    ) throws {
        try process(emit: emit, isFinal: true)
        switch state {
        case .finished:
            return
        case .seekingFirstBoundary:
            throw NetworkError.configuration(
                reason: .invalidRequest(
                    "Multipart response body did not contain the boundary delimiter."
                ))
        case .readingHeaders, .readingBody:
            throw NetworkError.configuration(reason: .invalidRequest("Missing multipart closing boundary."))
        }
    }

    private mutating func process(
        emit: (MultipartStreamingEvent) -> Void,
        isFinal: Bool = false
    ) throws {
        while true {
            switch state {
            case .seekingFirstBoundary:
                guard let boundary = nextBoundary(isFinal: isFinal) else {
                    discardPreambleTailIfNeeded(isFinal: isFinal)
                    return
                }
                buffer.removeSubrange(buffer.startIndex..<boundary.contentStart)
                state = boundary.isClosing ? .finished : .readingHeaders
                if boundary.isClosing { return }

            case .readingHeaders:
                if buffer.count > Self.maxPartHeaderBytes {
                    throw NetworkError.configuration(
                        reason: .invalidRequest(
                            "Multipart part headers exceed \(Self.maxPartHeaderBytes) bytes without a closing delimiter."
                        )
                    )
                }
                guard let separator = buffer.headerSeparatorRange else { return }
                let headerData = buffer[..<separator.lowerBound]
                let headers = try parseHeaders(headerData)
                buffer.removeSubrange(buffer.startIndex..<separator.upperBound)
                emit(.partStarted(headers: headers))
                state = .readingBody

            case .readingBody:
                guard let boundary = nextBoundary(isFinal: isFinal) else {
                    emitSafeBodyPrefix(emit: emit, isFinal: isFinal)
                    return
                }
                var bodyEnd = boundary.delimiterStart
                trimTrailingLineBreak(in: buffer, end: &bodyEnd)
                if buffer.startIndex < bodyEnd {
                    emit(.bodyChunk(Data(buffer[buffer.startIndex..<bodyEnd])))
                }
                emit(.partEnded)
                buffer.removeSubrange(buffer.startIndex..<boundary.contentStart)
                state = boundary.isClosing ? .finished : .readingHeaders
                if boundary.isClosing { return }

            case .finished:
                return
            }
        }
    }

    private mutating func discardPreambleTailIfNeeded(isFinal: Bool) {
        guard !isFinal else { return }
        let keep = delimiter.count + 4
        if buffer.count > keep {
            buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.endIndex, offsetBy: -keep))
        }
    }

    private mutating func emitSafeBodyPrefix(
        emit: (MultipartStreamingEvent) -> Void,
        isFinal: Bool
    ) {
        guard !isFinal else { return }
        let keep = delimiter.count + 4
        guard buffer.count > keep else { return }
        let emitEnd = buffer.index(buffer.endIndex, offsetBy: -keep)
        emit(.bodyChunk(Data(buffer[buffer.startIndex..<emitEnd])))
        buffer.removeSubrange(buffer.startIndex..<emitEnd)
    }

    private struct Boundary {
        let delimiterStart: Data.Index
        let contentStart: Data.Index
        let isClosing: Bool
    }

    private func nextBoundary(isFinal: Bool) -> Boundary? {
        var searchStart = buffer.startIndex
        while let range = buffer.range(of: delimiter, options: [], in: searchStart..<buffer.endIndex) {
            defer { searchStart = range.upperBound }
            guard isDelimiterLineStart(at: range.lowerBound),
                let boundary = boundary(delimiterRange: range, isFinal: isFinal)
            else {
                continue
            }
            return boundary
        }
        return nil
    }

    private func isDelimiterLineStart(at index: Data.Index) -> Bool {
        guard index != buffer.startIndex else { return true }
        return buffer[buffer.index(before: index)] == UInt8(ascii: "\n")
    }

    private func boundary(delimiterRange: Range<Data.Index>, isFinal: Bool) -> Boundary? {
        var cursor = delimiterRange.upperBound
        guard cursor != buffer.endIndex || isFinal else { return nil }
        let isClosing = buffer.hasPrefix(Data("--".utf8), at: cursor)
        if isClosing {
            cursor = buffer.index(cursor, offsetBy: 2)
        }

        if buffer.hasPrefix(Data("\r\n".utf8), at: cursor) {
            cursor = buffer.index(cursor, offsetBy: 2)
        } else if buffer.hasPrefix(Data("\n".utf8), at: cursor) {
            cursor = buffer.index(after: cursor)
        } else if cursor != buffer.endIndex {
            return nil
        }

        return Boundary(
            delimiterStart: delimiterRange.lowerBound,
            contentStart: cursor,
            isClosing: isClosing
        )
    }

    private func parseHeaders(_ data: Data.SubSequence) throws -> [String: String] {
        guard let headerBlock = String(data: data, encoding: .utf8) else {
            throw NetworkError.configuration(reason: .invalidRequest("Multipart headers are not UTF-8 decodable."))
        }

        var headers: [String: String] = [:]
        for line in headerBlock.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
        {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            headers[String(pair[0]).trimmingCharacters(in: .whitespaces)] =
                String(pair[1]).trimmingCharacters(in: .whitespaces)
        }
        return headers
    }
}
