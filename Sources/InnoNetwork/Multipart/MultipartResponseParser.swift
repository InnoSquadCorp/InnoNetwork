import Foundation

/// Shared framing state machine. Pulling one event at a time lets async callers
/// await delivery without buffering the remaining events from an input chunk.
struct MultipartResponseParser {
    static let sliceBytes = 16 * 1024
    static let maximumHeaderBytes = 1024 * 1024
    static let maximumPaddingBytes = 1024 * 1024

    private enum State { case preamble, headers, body, ended, finished }
    private let delimiter: Data
    private var state: State = .preamble
    private var buffer = Data()
    private var startsLine = true
    private var closing = false
    // Offsets are relative to buffer.startIndex and rebased when bytes leave.
    private var boundarySearchOffset = 0
    private var headerSearchOffset = 0
    private var pendingBoundary: PendingBoundary?

    #if DEBUG
    // Deterministic search-work bound for resource regression tests. This
    // counter and its updates are absent from optimized production builds.
    private(set) var scannedByteCount = 0
    #endif

    @inline(__always)
    private mutating func recordScanWork(_ count: Int) {
        #if DEBUG
        scannedByteCount += count
        #endif
    }

    init(boundary: String?) throws {
        guard let boundary, !boundary.isEmpty, boundary.utf8.count <= 70,
            !boundary.contains("\r"), !boundary.contains("\n")
        else { throw Self.invalid("Missing or invalid multipart boundary (maximum 70 bytes).") }
        delimiter = Data("--\(boundary)".utf8)
    }

    static func boundary(from contentType: String) -> String? {
        var parameters = MultipartBoundaryParameter(contentType)
        return parameters.parse()
    }

    mutating func append(_ bytes: Data) {
        // Epilogue is deliberately discarded, including subsequent input chunks.
        guard state != .finished else { return }
        buffer.append(bytes)
    }

    mutating func next(isFinal: Bool = false) throws -> MultipartStreamingEvent? {
        while true {
            switch state {
            case .preamble, .body:
                let search = try boundarySearch(isFinal: isFinal)
                if let boundary = search.boundary {
                    let wasBody = state == .body
                    let bodyEnd = withoutLineBreak(before: boundary.start)
                    let body = wasBody ? Data(buffer[..<bodyEnd]) : Data()
                    discard(through: boundary.end)
                    resetSearches()
                    closing = boundary.closing
                    state = wasBody ? .ended : (closing ? .finished : .headers)
                    if state == .finished { buffer.removeAll(keepingCapacity: false) }
                    if !body.isEmpty { return .bodyChunk(body) }
                    continue
                }
                if isFinal {
                    throw Self.invalid(
                        state == .preamble
                            ? "Multipart response body did not contain the boundary delimiter."
                            : "Missing multipart closing boundary.")
                }
                // Preserve both partial delimiters and their preceding CRLF.
                let safeEnd = search.safeEnd
                guard safeEnd > buffer.startIndex else { return nil }
                let body = state == .body ? Data(buffer[..<safeEnd]) : Data()
                discard(through: safeEnd)
                if !body.isEmpty { return .bodyChunk(body) }
                return nil
            case .headers:
                guard let separator = headerSeparator() else {
                    // Three bytes may belong to an incomplete CRLFCRLF terminator.
                    guard buffer.count <= Self.maximumHeaderBytes + 3 else {
                        throw Self.invalid("Multipart part headers exceed \(Self.maximumHeaderBytes) bytes.")
                    }
                    if isFinal { throw Self.invalid("Missing multipart closing boundary.") }
                    return nil
                }
                guard separator.lowerBound - buffer.startIndex <= Self.maximumHeaderBytes else {
                    throw Self.invalid("Multipart part headers exceed \(Self.maximumHeaderBytes) bytes.")
                }
                let headers = try parseHeaders(buffer[..<separator.lowerBound])
                discard(through: separator.upperBound)
                resetSearches()
                state = .body
                return .partStarted(headers: headers)
            case .ended:
                state = closing ? .finished : .headers
                if closing { buffer.removeAll(keepingCapacity: false) }
                return .partEnded
            case .finished:
                return nil
            }
        }
    }

    private mutating func discard(through end: Data.Index) {
        let count = end - buffer.startIndex
        if end > buffer.startIndex { startsLine = buffer[end - 1] == 10 }
        buffer.removeSubrange(buffer.startIndex..<end)
        boundarySearchOffset = max(0, boundarySearchOffset - count)
        headerSearchOffset = max(0, headerSearchOffset - count)
        if var pending = pendingBoundary {
            pending.start -= count
            pending.cursor -= count
            pendingBoundary = pending
        }
    }

    private mutating func resetSearches() {
        boundarySearchOffset = 0
        headerSearchOffset = 0
        pendingBoundary = nil
    }

    private func withoutLineBreak(before end: Data.Index) -> Data.Index {
        var end = end
        if end > buffer.startIndex, buffer[end - 1] == 10 {
            end -= 1
            if end > buffer.startIndex, buffer[end - 1] == 13 { end -= 1 }
        }
        return end
    }

    private struct Boundary {
        let start: Data.Index
        let end: Data.Index
        let closing: Bool
    }

    private struct PendingBoundary {
        enum Phase { case suffix, secondDash, padding, lineFeed }
        var start: Int
        var cursor: Int
        var phase: Phase = .suffix
        var closing = false
        var padding = 0
    }

    private enum BoundaryProgress { case complete, incomplete, invalid }

    private mutating func boundarySearch(isFinal: Bool) throws -> (boundary: Boundary?, safeEnd: Data.Index) {
        let safeEnd = max(buffer.startIndex, buffer.endIndex - delimiter.count - 6)
        while true {
            if var pending = pendingBoundary {
                switch try advanceBoundary(&pending, isFinal: isFinal) {
                case .complete:
                    pendingBoundary = nil
                    return (
                        Boundary(
                            start: buffer.startIndex + pending.start, end: buffer.startIndex + pending.cursor,
                            closing: pending.closing), safeEnd
                    )
                case .incomplete:
                    pendingBoundary = pending
                    return (nil, min(safeEnd, withoutLineBreak(before: buffer.startIndex + pending.start)))
                case .invalid:
                    pendingBoundary = nil
                    boundarySearchOffset = pending.start + 1
                }
            }
            let searchStart = buffer.startIndex + boundarySearchOffset
            let found = buffer.range(of: delimiter, in: searchStart..<buffer.endIndex)
            recordScanWork((found?.upperBound ?? buffer.endIndex) - searchStart)
            guard let range = found else {
                // Only a delimiter-length overlap can become a new match.
                boundarySearchOffset = max(0, buffer.count - delimiter.count + 1)
                return (nil, safeEnd)
            }
            boundarySearchOffset = range.lowerBound - buffer.startIndex + 1
            let atLineStart = range.lowerBound == buffer.startIndex ? startsLine : buffer[range.lowerBound - 1] == 10
            guard atLineStart else { continue }
            pendingBoundary = PendingBoundary(
                start: range.lowerBound - buffer.startIndex, cursor: range.upperBound - buffer.startIndex)
        }
    }

    private mutating func advanceBoundary(_ pending: inout PendingBoundary, isFinal: Bool) throws -> BoundaryProgress {
        while true {
            guard pending.cursor < buffer.count else {
                guard isFinal else { return .incomplete }
                return pending.phase == .suffix || pending.phase == .padding ? .complete : .invalid
            }
            let byte = buffer[buffer.startIndex + pending.cursor]
            recordScanWork(1)
            switch pending.phase {
            case .suffix:
                if byte == 45 {
                    pending.cursor += 1
                    pending.phase = .secondDash
                } else {
                    pending.phase = .padding
                }
            case .secondDash:
                guard byte == 45 else { return .invalid }
                pending.cursor += 1
                pending.closing = true
                pending.phase = .padding
            case .padding:
                if byte == 32 || byte == 9 {
                    pending.padding += 1
                    guard pending.padding <= Self.maximumPaddingBytes else {
                        throw Self.invalid("Multipart boundary padding exceeds \(Self.maximumPaddingBytes) bytes.")
                    }
                    pending.cursor += 1
                } else if byte == 13 {
                    pending.cursor += 1
                    pending.phase = .lineFeed
                } else if byte == 10 {
                    pending.cursor += 1
                    return .complete
                } else {
                    return .invalid
                }
            case .lineFeed:
                guard byte == 10 else { return .invalid }
                pending.cursor += 1
                return .complete
            }
        }
    }

    private mutating func headerSeparator() -> Range<Data.Index>? {
        let start = buffer.startIndex
        if buffer.starts(with: [13, 10]) { return start..<start + 2 }
        if buffer.first == 10 { return start..<start + 1 }
        let searchStart = start + headerSearchOffset
        let range = searchStart..<buffer.endIndex
        recordScanWork(range.count * 2)
        let crlf = buffer.range(of: Data("\r\n\r\n".utf8), in: range)
        let lf = buffer.range(of: Data("\n\n".utf8), in: range)
        headerSearchOffset = max(0, buffer.count - 3)
        return [crlf, lf].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
    }

    private func parseHeaders(_ bytes: Data) throws -> [String: String] {
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw Self.invalid("Multipart headers are not UTF-8 decodable.")
        }
        var headers: [String: String] = [:]
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            headers[String(pair[0]).trimmingCharacters(in: .whitespaces)] =
                String(pair[1]).trimmingCharacters(in: .whitespaces)
        }
        return headers
    }

    private static func invalid(_ message: String) -> NetworkError {
        .configuration(reason: .invalidRequest(message))
    }
}
