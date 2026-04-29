import Foundation

/// One part in a decoded `multipart/*` response body.
public struct MultipartPart: Sendable, Equatable {
    public let headers: [String: String]
    public let data: Data

    public init(headers: [String: String], data: Data) {
        self.headers = headers
        self.data = data
    }
}


/// Decoder for buffered `multipart/*` response bodies.
public struct MultipartResponseDecoder: Sendable {
    private let boundaryOverride: String?

    public init(boundary: String? = nil) {
        self.boundaryOverride = boundary
    }

    public func decode(_ data: Data, contentType: String) throws -> [MultipartPart] {
        guard let boundary = boundaryOverride ?? Self.boundary(from: contentType), !boundary.isEmpty else {
            throw NetworkError.invalidRequestConfiguration("Missing multipart boundary.")
        }

        let delimiter = Data("--\(boundary)".utf8)
        var parts: [MultipartPart] = []
        var searchStart = data.startIndex

        while let boundaryRange = data.range(of: delimiter, options: [], in: searchStart..<data.endIndex) {
            var partStart = boundaryRange.upperBound
            if data.hasPrefix(Data("--".utf8), at: partStart) {
                break
            }

            skipLineBreak(in: data, index: &partStart)
            guard let nextBoundary = data.range(of: delimiter, options: [], in: partStart..<data.endIndex) else {
                throw NetworkError.invalidRequestConfiguration("Missing multipart closing boundary.")
            }

            var partEnd = nextBoundary.lowerBound
            trimTrailingLineBreak(in: data, end: &partEnd)
            if partStart < partEnd {
                parts.append(try decodePart(data[partStart..<partEnd]))
            }
            searchStart = nextBoundary.lowerBound
        }

        return parts
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
