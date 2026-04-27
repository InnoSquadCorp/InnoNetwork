import Foundation
import OSLog
import UniformTypeIdentifiers


public struct MultipartFormData: Sendable {
    public let boundary: String
    private var parts: [Part]

    public init(boundary: String = "InnoNetwork.boundary.\(UUID().uuidString)") {
        self.boundary = boundary
        self.parts = []
    }

    public mutating func append(_ data: Data, name: String, fileName: String? = nil, mimeType: String? = nil) {
        parts.append(Part(source: .data(data), name: name, fileName: fileName, mimeType: mimeType))
    }

    public mutating func append(_ string: String, name: String) {
        if let data = string.data(using: .utf8) {
            parts.append(Part(source: .data(data), name: name, fileName: nil, mimeType: nil))
        }
    }

    public mutating func append(_ value: Int, name: String) {
        append(String(value), name: name)
    }

    public mutating func append(_ value: Double, name: String) {
        append(String(value), name: name)
    }

    public mutating func append(_ value: Bool, name: String) {
        append(value ? "true" : "false", name: name)
    }

    /// Appends a file from disk by reading its entire contents into memory
    /// at append time.
    ///
    /// This works for small attachments but is not safe for large media —
    /// 100MB videos can trigger jetsam on iOS. Use the asynchronous variant
    /// ``appendFile(at:name:mimeType:)-async`` and pair it with
    /// ``writeEncodedData(to:)`` to stream the body to disk instead.
    @available(*, deprecated, message: "Use the async appendFile(at:name:mimeType:) overload combined with writeEncodedData(to:) to avoid loading the file into memory.")
    public mutating func appendFile(at url: URL, name: String, mimeType: String? = nil) throws {
        let data = try Data(contentsOf: url)
        let fileName = url.lastPathComponent
        let detectedMimeType = mimeType ?? Self.mimeType(for: url.pathExtension)
        parts.append(Part(source: .data(data), name: name, fileName: fileName, mimeType: detectedMimeType))
    }

    /// Appends a file by URL without reading its contents.
    ///
    /// The bytes are streamed at the time the body is encoded — either
    /// lazily into memory by ``encode()`` or chunk-by-chunk to disk by
    /// ``writeEncodedData(to:)``. Prefer the latter for any payload that
    /// could exceed a few megabytes.
    public mutating func appendFile(at url: URL, name: String, mimeType: String? = nil) async throws {
        let fileName = url.lastPathComponent
        let detectedMimeType = mimeType ?? Self.mimeType(for: url.pathExtension)
        parts.append(Part(source: .file(url), name: name, fileName: fileName, mimeType: detectedMimeType))
    }

    /// Returns the encoded multipart body as a single in-memory `Data`.
    ///
    /// Use this for small bodies where memory pressure is not a concern.
    /// For large file uploads, prefer ``writeEncodedData(to:)`` so the
    /// body is streamed chunk-by-chunk to disk and uploaded via
    /// `URLSession.upload(for:fromFile:)`. File parts that cannot be read
    /// are skipped entirely and logged as warnings; use
    /// ``writeEncodedData(to:)`` when read failures must be surfaced to the
    /// caller.
    public func encode() -> Data {
        var body = Data()
        let boundaryPrefix = "--\(boundary)\r\n"

        for part in parts {
            let partData: Data
            switch part.source {
            case .data(let data):
                partData = data
            case .file(let url):
                do {
                    partData = try Data(contentsOf: url)
                } catch {
                    Logger.API.warning("multipart_encode_skipped_file boundary=\(boundary, privacy: .public) name=\(part.name, privacy: .private(mask: .hash)) file=\(url.lastPathComponent, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private)")
                    continue
                }
            }
            body.append(Data(boundaryPrefix.utf8))
            body.append(part.headerData())
            body.append(partData)
            body.append(Data("\r\n".utf8))
        }

        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    /// Streams the encoded multipart body to a file on disk, reading file
    /// parts in 64 KiB chunks so peak memory stays bounded regardless of
    /// the source file's size.
    ///
    /// This method performs synchronous disk I/O and may block its caller for
    /// large bodies. Invoke it from a background context rather than from
    /// `MainActor` or latency-sensitive structured tasks.
    ///
    /// If a write fails, the destination may be left partially written.
    /// Callers should remove the temporary file before retrying or surfacing
    /// the failure, typically with `defer { try? FileManager.default.removeItem(at: fileURL) }`.
    ///
    /// - Parameter fileURL: Destination URL. Any existing file at this
    ///   location is overwritten. The caller is responsible for placing the
    ///   destination on a writable volume — typically the temp directory.
    /// - Throws: Any I/O error encountered while opening the destination
    ///   file or reading source files.
    public func writeEncodedData(to fileURL: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: fileURL.path) {
            try manager.removeItem(at: fileURL)
        }
        manager.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        let boundaryPrefix = Data("--\(boundary)\r\n".utf8)
        let crlf = Data("\r\n".utf8)
        let chunkSize = 64 * 1024

        for part in parts {
            try handle.write(contentsOf: boundaryPrefix)
            try handle.write(contentsOf: part.headerData())

            switch part.source {
            case .data(let data):
                try handle.write(contentsOf: data)
            case .file(let url):
                let source = try FileHandle(forReadingFrom: url)
                defer { try? source.close() }
                while true {
                    let chunk = try source.read(upToCount: chunkSize) ?? Data()
                    if chunk.isEmpty { break }
                    try handle.write(contentsOf: chunk)
                }
            }
            try handle.write(contentsOf: crlf)
        }

        try handle.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
    }

    public var contentTypeHeader: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// Estimated encoded size in bytes, used by the executor to decide whether
    /// to keep the body in memory or stream it to disk.
    ///
    /// For data parts the size is exact. For file parts the size is read from
    /// `FileManager` attributes — so it is exact unless the file is missing,
    /// in which case the estimator treats the part as zero bytes (the encoder
    /// will skip the part later, matching ``encode()``'s behavior). The
    /// per-part headers and boundary frame are accounted for so the result
    /// is a tight upper bound rather than a partial sum.
    public var estimatedEncodedSize: Int64 {
        let boundaryLine = "--\(boundary)\r\n".utf8.count
        let trailingBoundary = "--\(boundary)--\r\n".utf8.count
        let crlf = "\r\n".utf8.count

        var total: Int64 = Int64(trailingBoundary)
        for part in parts {
            total += Int64(boundaryLine)
            total += Int64(part.headerData().count)
            switch part.source {
            case .data(let data):
                total += Int64(data.count)
            case .file(let url):
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                total += size
            }
            total += Int64(crlf)
        }
        return total
    }

    static func mimeType(for pathExtension: String) -> String {
        // UTType is available on every platform InnoNetwork ships against
        // (iOS 18+, macOS 15+, tvOS 18+, watchOS 11+, visionOS 2+), so it
        // can replace the hand-curated extension table without an
        // availability shim. The fallback matches the previous default of
        // application/octet-stream for unknown extensions.
        UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}


extension MultipartFormData {
    struct Part: Sendable {
        let source: Source
        let name: String
        let fileName: String?
        let mimeType: String?

        func headerData() -> Data {
            var disposition = "Content-Disposition: form-data; name=\"\(name)\""
            if let fileName {
                disposition += "; filename=\"\(fileName)\""
            }
            disposition += "\r\n"
            var data = Data(disposition.utf8)
            if let mimeType {
                data.append(Data("Content-Type: \(mimeType)\r\n".utf8))
            }
            data.append(Data("\r\n".utf8))
            return data
        }
    }

    enum Source: Sendable {
        case data(Data)
        case file(URL)
    }
}
