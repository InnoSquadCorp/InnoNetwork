import Foundation

/// One part in a decoded `multipart/*` response body.
public struct MultipartPart: Sendable, Equatable {
    /// Header fields parsed from the part header block.
    public let headers: [String: String]
    /// Raw payload bytes for the part body.
    public let data: Data

    /// Creates a decoded multipart part value.
    ///
    /// - Parameters:
    ///   - headers: Header fields parsed from the part header block.
    ///   - data: Raw payload bytes for the part body.
    public init(headers: [String: String], data: Data) {
        self.headers = headers
        self.data = data
    }
}


/// Decoder for buffered `multipart/*` response bodies.
///
/// The decoder reads an explicit boundary override first. If no override is
/// supplied, it extracts the `boundary` parameter from the response
/// `Content-Type` passed to ``decode(_:contentType:)``.
public struct MultipartResponseDecoder: Sendable {
    private let boundaryOverride: String?

    /// Creates a decoder.
    ///
    /// - Parameter boundary: Optional boundary override. When `nil`, the
    ///   decoder reads the `boundary` parameter from the response
    ///   `Content-Type` header passed to ``decode(_:contentType:)``.
    public init(boundary: String? = nil) {
        self.boundaryOverride = boundary
    }

    /// Decodes a buffered `multipart/*` response body into ordered parts.
    ///
    /// Boundary delimiters are recognized only when they appear as delimiter
    /// lines (`--boundary` or `--boundary--`) at the start of the body or
    /// after a line break. Matching bytes inside part payloads are preserved.
    ///
    /// - Parameters:
    ///   - data: Complete multipart response body.
    ///   - contentType: Response `Content-Type` header containing a
    ///     `boundary` parameter, unless a boundary override was supplied.
    /// - Returns: Decoded parts in response order.
    /// - Throws: ``NetworkError/invalidRequestConfiguration(_:)`` when the
    ///   boundary is missing, a part is malformed, or the closing boundary is
    ///   absent.
    public func decode(_ data: Data, contentType: String) throws -> [MultipartPart] {
        guard let boundary = boundaryOverride ?? Self.boundary(from: contentType), !boundary.isEmpty else {
            throw NetworkError.invalidRequestConfiguration("Missing multipart boundary.")
        }

        let delimiter = Data("--\(boundary)".utf8)
        guard var currentBoundary = nextBoundary(in: data, delimiter: delimiter, after: data.startIndex) else {
            return []
        }

        var parts: [MultipartPart] = []
        while !currentBoundary.isClosing {
            let partStart = currentBoundary.contentStart
            guard let nextBoundary = nextBoundary(in: data, delimiter: delimiter, after: partStart) else {
                throw NetworkError.invalidRequestConfiguration("Missing multipart closing boundary.")
            }

            var partEnd = nextBoundary.delimiterStart
            trimTrailingLineBreak(in: data, end: &partEnd)
            if partStart < partEnd {
                parts.append(try decodePart(data[partStart..<partEnd]))
            }
            currentBoundary = nextBoundary
        }

        return parts
    }

    private struct Boundary {
        let delimiterStart: Data.Index
        let contentStart: Data.Index
        let isClosing: Bool
    }

    private func nextBoundary(in data: Data, delimiter: Data, after index: Data.Index) -> Boundary? {
        var searchStart = index
        while let range = data.range(of: delimiter, options: [], in: searchStart..<data.endIndex) {
            defer { searchStart = range.upperBound }
            guard isDelimiterLineStart(in: data, at: range.lowerBound),
                let boundary = boundary(in: data, delimiterRange: range)
            else {
                continue
            }
            return boundary
        }
        return nil
    }

    private func isDelimiterLineStart(in data: Data, at index: Data.Index) -> Bool {
        guard index != data.startIndex else { return true }
        return data[data.index(before: index)] == UInt8(ascii: "\n")
    }

    private func boundary(in data: Data, delimiterRange: Range<Data.Index>) -> Boundary? {
        var cursor = delimiterRange.upperBound
        let isClosing = data.hasPrefix(Data("--".utf8), at: cursor)
        if isClosing {
            cursor = data.index(cursor, offsetBy: 2)
        }

        if data.hasPrefix(Data("\r\n".utf8), at: cursor) {
            cursor = data.index(cursor, offsetBy: 2)
        } else if data.hasPrefix(Data("\n".utf8), at: cursor) {
            cursor = data.index(after: cursor)
        } else if cursor != data.endIndex {
            return nil
        }

        return Boundary(
            delimiterStart: delimiterRange.lowerBound,
            contentStart: cursor,
            isClosing: isClosing
        )
    }

    private func decodePart(_ rawPart: Data.SubSequence) throws -> MultipartPart {
        let part = Data(rawPart)
        guard let separator = part.headerSeparatorRange else {
            throw NetworkError.invalidRequestConfiguration("Malformed multipart part.")
        }
        let headerData = part[..<separator.lowerBound]
        let bodyStart = separator.upperBound
        let body = part[bodyStart..<part.endIndex]
        guard let headerBlock = String(data: headerData, encoding: .utf8) else {
            throw NetworkError.invalidRequestConfiguration("Multipart headers are not UTF-8 decodable.")
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
        return MultipartPart(headers: headers, data: Data(body))
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


private func skipLineBreak(in data: Data, index: inout Data.Index) {
    if data.hasPrefix(Data("\r\n".utf8), at: index) {
        index = data.index(index, offsetBy: 2)
    } else if data.hasPrefix(Data("\n".utf8), at: index) {
        index = data.index(after: index)
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
