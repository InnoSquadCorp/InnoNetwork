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
    /// - Throws: ``NetworkError/configuration(reason:)`` with
    ///   ``NetworkConfigurationFailureReason/invalidRequest(_:)`` when the
    ///   boundary is missing, a part is malformed, or the closing boundary
    ///   is absent.
    public func decode(_ data: Data, contentType: String) throws -> [MultipartPart] {
        var parser = try MultipartResponseParser(
            boundary: boundaryOverride ?? MultipartResponseParser.boundary(from: contentType))
        var parts: [MultipartPart] = []
        var headers: [String: String] = [:]
        var body = Data()
        func collect(_ event: MultipartStreamingEvent) {
            switch event {
            case .partStarted(let fields):
                headers = fields
                body = Data()
            case .bodyChunk(let bytes): body.append(bytes)
            case .partEnded: parts.append(MultipartPart(headers: headers, data: body))
            }
        }
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(data.endIndex, offset + MultipartResponseParser.sliceBytes)
            parser.append(Data(data[offset..<end]))
            while let event = try parser.next() { collect(event) }
            offset = end
        }
        while let event = try parser.next(isFinal: true) { collect(event) }
        return parts
    }
}
