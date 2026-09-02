#if canImport(AVFoundation) && canImport(Network)
import Foundation

struct HLSLocalPlaybackHTTPRequest {
    enum Method: Equatable {
        case get
        case head
    }

    let method: Method
    let target: String
    let range: HLSLocalPlaybackRequestedRange

    init(header: Data) throws {
        guard let text = String(data: header, encoding: .utf8),
            let terminator = text.range(of: "\r\n\r\n")
        else {
            throw HLSLocalPlaybackHTTPError.badRequest
        }
        let lines = text[..<terminator.lowerBound]
            .components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HLSLocalPlaybackHTTPError.badRequest
        }
        let parts = requestLine.split(
            separator: " ",
            omittingEmptySubsequences: true
        )
        guard parts.count == 3,
            parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
        else {
            throw HLSLocalPlaybackHTTPError.badRequest
        }
        switch parts[0] {
        case "GET":
            method = .get
        case "HEAD":
            method = .head
        default:
            throw HLSLocalPlaybackHTTPError.methodNotAllowed
        }
        target = String(parts[1])
        var rangeValue: String?
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                throw HLSLocalPlaybackHTTPError.badRequest
            }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if name == "range" {
                guard rangeValue == nil else {
                    throw HLSLocalPlaybackHTTPError.badRequest
                }
                rangeValue = value
            }
        }
        range = try HLSLocalPlaybackRequestedRange(
            headerValue: rangeValue
        )
    }
}

enum HLSLocalPlaybackRequestedRange {
    case entireResource
    case closed(start: Int64, end: Int64)
    case openEnded(start: Int64)
    case suffix(length: Int64)

    init(headerValue: String?) throws {
        guard let headerValue else {
            self = .entireResource
            return
        }
        guard headerValue.hasPrefix("bytes="),
            !headerValue.contains(",")
        else {
            throw HLSLocalPlaybackHTTPError.rangeNotSatisfiable
        }
        let value = headerValue.dropFirst("bytes=".count)
        guard let separator = value.firstIndex(of: "-") else {
            throw HLSLocalPlaybackHTTPError.rangeNotSatisfiable
        }
        let startValue = value[..<separator]
        let endValue = value[value.index(after: separator)...]
        if startValue.isEmpty {
            guard let length = Int64(endValue), length > 0 else {
                throw HLSLocalPlaybackHTTPError.rangeNotSatisfiable
            }
            self = .suffix(length: length)
            return
        }
        guard let start = Int64(startValue), start >= 0 else {
            throw HLSLocalPlaybackHTTPError.rangeNotSatisfiable
        }
        if endValue.isEmpty {
            self = .openEnded(start: start)
            return
        }
        guard let end = Int64(endValue), end >= start else {
            throw HLSLocalPlaybackHTTPError.rangeNotSatisfiable
        }
        self = .closed(start: start, end: end)
    }

    func resolve(
        fileSize: Int64
    ) throws -> HLSLocalPlaybackResolvedRange {
        guard fileSize >= 0 else {
            throw HLSLocalPlaybackHTTPError.internalFailure
        }
        switch self {
        case .entireResource:
            return HLSLocalPlaybackResolvedRange(
                start: 0,
                length: fileSize,
                fileSize: fileSize,
                isPartial: false
            )
        case .closed(let start, let requestedEnd):
            guard start < fileSize else {
                throw HLSLocalPlaybackHTTPError
                    .rangeNotSatisfiable
            }
            let end = min(requestedEnd, fileSize - 1)
            return HLSLocalPlaybackResolvedRange(
                start: start,
                length: end - start + 1,
                fileSize: fileSize,
                isPartial: true
            )
        case .openEnded(let start):
            guard start < fileSize else {
                throw HLSLocalPlaybackHTTPError
                    .rangeNotSatisfiable
            }
            return HLSLocalPlaybackResolvedRange(
                start: start,
                length: fileSize - start,
                fileSize: fileSize,
                isPartial: true
            )
        case .suffix(let requestedLength):
            guard fileSize > 0 else {
                throw HLSLocalPlaybackHTTPError
                    .rangeNotSatisfiable
            }
            let length = min(requestedLength, fileSize)
            return HLSLocalPlaybackResolvedRange(
                start: fileSize - length,
                length: length,
                fileSize: fileSize,
                isPartial: true
            )
        }
    }
}

struct HLSLocalPlaybackResolvedRange: Equatable {
    let start: Int64
    let length: Int64
    let fileSize: Int64
    let isPartial: Bool
}

enum HLSLocalPlaybackHTTPError: Error, Equatable {
    case badRequest
    case forbidden
    case notFound
    case methodNotAllowed
    case rangeNotSatisfiable
    case internalFailure
}

enum HLSLocalPlaybackHTTPResponse {
    static func successHeader(
        file: HLSLocalPlaybackFile,
        range: HLSLocalPlaybackResolvedRange
    ) -> Data {
        var lines = [
            range.isPartial
                ? "HTTP/1.1 206 Partial Content"
                : "HTTP/1.1 200 OK",
            "Content-Type: \(file.contentType)",
            "Content-Length: \(range.length)",
            "Accept-Ranges: bytes",
            "Connection: close",
        ]
        if range.isPartial {
            let end = range.start + range.length - 1
            lines.insert(
                "Content-Range: bytes \(range.start)-\(end)/\(range.fileSize)",
                at: 3
            )
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    static func errorHeader(
        _ error: HLSLocalPlaybackHTTPError
    ) -> Data {
        let status: String
        switch error {
        case .badRequest:
            status = "400 Bad Request"
        case .forbidden:
            status = "403 Forbidden"
        case .notFound:
            status = "404 Not Found"
        case .methodNotAllowed:
            status = "405 Method Not Allowed"
        case .rangeNotSatisfiable:
            status = "416 Range Not Satisfiable"
        case .internalFailure:
            status = "500 Internal Server Error"
        }
        return Data(
            ("HTTP/1.1 \(status)\r\n"
                + "Content-Length: 0\r\n"
                + "Connection: close\r\n\r\n").utf8
        )
    }
}
#endif
