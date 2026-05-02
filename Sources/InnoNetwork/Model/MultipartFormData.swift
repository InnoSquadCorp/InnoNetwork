import Foundation
import OSLog
import UniformTypeIdentifiers

public struct MultipartFormData: Sendable {
    public let boundary: String
    /// When `true`, every part's preamble emits a `Content-Length: <bytes>`
    /// header alongside `Content-Disposition`. The default is `false`
    /// because most servers ignore per-part `Content-Length`, the value
    /// must be precomputed for streaming sources, and emitting it can
    /// surprise interceptors that re-encode the body.
    public var includesPartContentLength: Bool
    /// When `true`, ``writeEncodedData(to:)`` calls `synchronize()` on the
    /// destination file handle before closing so the bytes survive an
    /// abrupt power loss between the write and the actual upload. The
    /// default is `false` because the temp file is uploaded immediately
    /// in the same process and the extra fsync is wasteful for that flow.
    public var synchronizesEncodedFile: Bool
    private var parts: [Part]

    public init(
        boundary: String = "InnoNetwork.boundary.\(UUID().uuidString)",
        includesPartContentLength: Bool = false,
        synchronizesEncodedFile: Bool = false
    ) {
        self.boundary = Self.sanitizedBoundary(boundary) ?? "InnoNetwork.boundary.\(UUID().uuidString)"
        self.includesPartContentLength = includesPartContentLength
        self.synchronizesEncodedFile = synchronizesEncodedFile
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

    /// Appends a file by URL without reading its contents.
    ///
    /// File reachability is checked at append time so the encoder fails
    /// fast at the call site instead of swallowing missing files at
    /// encode time. The bytes themselves are streamed later — lazily
    /// into memory by ``encode()`` or chunk-by-chunk to disk by
    /// ``writeEncodedData(to:)``. Prefer the latter for any payload that
    /// could exceed a few megabytes.
    ///
    /// - Parameters:
    ///   - url: Local file URL.
    ///   - name: Form field name.
    ///   - mimeType: Optional MIME override; otherwise inferred from the
    ///     file extension.
    /// - Throws: ``NetworkError/invalidRequestConfiguration(_:)`` when the
    ///   URL does not point at a regular readable file.
    public mutating func appendFile(at url: URL, name: String, mimeType: String? = nil) throws {
        guard url.isFileURL else {
            throw NetworkError.invalidRequestConfiguration(
                "MultipartFormData.appendFile expects a file URL; got \(url.scheme ?? "non-file")."
            )
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue == false
        else {
            throw NetworkError.invalidRequestConfiguration(
                "MultipartFormData.appendFile could not locate a regular file at \(url.path)."
            )
        }
        let fileName = url.lastPathComponent
        let detectedMimeType = mimeType ?? Self.mimeType(for: url.pathExtension)
        parts.append(Part(source: .file(url), name: name, fileName: fileName, mimeType: detectedMimeType))
    }

    /// Returns the encoded multipart body as a single in-memory `Data`.
    ///
    /// Use this for small bodies where memory pressure is not a concern.
    /// For large file uploads, prefer ``writeEncodedData(to:)`` so the
    /// body is streamed chunk-by-chunk to disk and uploaded via
    /// `URLSession.upload(for:fromFile:)`.
    ///
    /// - Throws: Any I/O error encountered while reading a file part.
    ///   Earlier versions silently skipped unreadable file parts; that
    ///   masked configuration bugs (typoed paths, files removed between
    ///   ``appendFile(at:name:mimeType:)`` and encoding) so reads now
    ///   surface their underlying error to the caller.
    public func encode() throws -> Data {
        var body = Data()
        let boundaryPrefix = "--\(boundary)\r\n"

        for part in parts {
            let partData: Data
            switch part.source {
            case .data(let data):
                partData = data
            case .file(let url):
                partData = try Data(contentsOf: url)
            }
            body.append(Data(boundaryPrefix.utf8))
            let contentLength: Int64? = includesPartContentLength ? Int64(partData.count) : nil
            body.append(part.headerData(contentLength: contentLength))
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

        // Manual close handling: `defer { try? handle.close() }` would
        // swallow disk-full or fsync errors detected at flush time, so
        // close explicitly on the success path and best-effort on
        // failure (after the original error has been captured).
        do {
            try writeBody(to: handle)
            if synchronizesEncodedFile {
                try handle.synchronize()
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func writeBody(to handle: FileHandle) throws {
        let boundaryPrefix = Data("--\(boundary)\r\n".utf8)
        let crlf = Data("\r\n".utf8)
        let chunkSize = 64 * 1024

        for part in parts {
            try handle.write(contentsOf: boundaryPrefix)
            let contentLength: Int64?
            if includesPartContentLength {
                switch part.source {
                case .data(let data):
                    contentLength = Int64(data.count)
                case .file(let url):
                    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                    contentLength = (attributes?[.size] as? NSNumber)?.int64Value
                }
            } else {
                contentLength = nil
            }
            try handle.write(contentsOf: part.headerData(contentLength: contentLength))

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
    /// `FileManager` attributes. If metadata lookup fails, the estimator uses a
    /// conservative sentinel so the executor prefers the streaming upload path
    /// instead of underestimating an unreadable or unexpectedly large file.
    /// The per-part headers and boundary frame are accounted for so the result
    /// is a tight upper bound when all file metadata is available.
    public var estimatedEncodedSize: Int64 {
        let boundaryLine = "--\(boundary)\r\n".utf8.count
        let trailingBoundary = "--\(boundary)--\r\n".utf8.count
        let crlf = "\r\n".utf8.count

        var total: Int64 = Int64(trailingBoundary)
        func add(_ value: Int64) {
            let added = total.addingReportingOverflow(value)
            total = added.overflow ? Int64.max : added.partialValue
        }

        for part in parts {
            add(Int64(boundaryLine))
            let partSize: Int64
            switch part.source {
            case .data(let data):
                partSize = Int64(data.count)
            case .file(let url):
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                partSize = (attributes?[.size] as? NSNumber)?.int64Value ?? Int64.max / 4
            }
            let contentLength: Int64? = includesPartContentLength ? partSize : nil
            add(Int64(part.headerData(contentLength: contentLength).count))
            add(partSize)
            add(Int64(crlf))
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

    private static func sanitizedBoundary(_ boundary: String) -> String? {
        var sanitized = ""
        sanitized.reserveCapacity(min(boundary.count, 70))
        var containsAllowedScalar = false

        for scalar in boundary.unicodeScalars {
            guard sanitized.count < 70 else { break }
            if isAllowedBoundaryScalar(scalar) {
                sanitized.unicodeScalars.append(scalar)
                containsAllowedScalar = true
            } else if sanitized.last != "-" {
                sanitized.append("-")
            }
        }

        return containsAllowedScalar ? sanitized : nil
    }

    private static func isAllowedBoundaryScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
            return true
        case 0x27, 0x28, 0x29, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x3A, 0x3D, 0x3F, 0x5F:
            return true
        default:
            return false
        }
    }
}


extension MultipartFormData {
    struct Part: Sendable {
        let source: Source
        let name: String
        let fileName: String?
        let mimeType: String?

        func headerData(contentLength: Int64? = nil) -> Data {
            // For non-ASCII field names, emit both the legacy `name=`
            // (with non-ASCII collapsed to `_`) and an RFC 5987
            // `name*=UTF-8''<percent>` companion so receivers that
            // understand the extended syntax can decode the original UTF-8
            // bytes. The `name=` ASCII fallback alone is ambiguous when
            // multiple non-ASCII parts collide on `_`.
            //
            // Interop note: RFC 7578 (multipart/form-data) does NOT
            // standardize `name*=` — only RFC 6266's `filename*=` is widely
            // interoperable. Most lenient parsers ignore the unknown
            // parameter and fall back to `name=`; strict implementations
            // could in theory reject it. In practice common stacks
            // (Express/multer, Spring, Rails, ASP.NET) tolerate it. Callers
            // who must target a strict parser can keep field names ASCII
            // to suppress emission. The companion is only added when the
            // name actually contains non-ASCII scalars; pure-ASCII names
            // keep wire-format unchanged.
            let asciiName = Self.asciiFallbackFilename(name)
            var disposition = "Content-Disposition: form-data; name=\"\(asciiName)\""
            if Self.requiresExtendedFilename(name) {
                disposition += "; name*=UTF-8''\(Self.rfc5987EncodedFilename(name))"
            }
            if let fileName {
                let asciiFallback = Self.asciiFallbackFilename(fileName)
                disposition += "; filename=\"\(asciiFallback)\""
                if Self.requiresExtendedFilename(fileName) {
                    disposition += "; filename*=UTF-8''\(Self.rfc5987EncodedFilename(fileName))"
                }
            }
            disposition += "\r\n"
            var data = Data(disposition.utf8)
            if let mimeType {
                data.append(Data("Content-Type: \(Self.escapedHeaderValue(mimeType))\r\n".utf8))
            }
            if let contentLength {
                data.append(Data("Content-Length: \(contentLength)\r\n".utf8))
            }
            data.append(Data("\r\n".utf8))
            return data
        }

        /// Detects whether the filename contains any byte that the legacy
        /// ASCII `filename` parameter cannot represent verbatim. RFC 6266
        /// §4.3 directs senders to additionally emit `filename*` (RFC 5987)
        /// in that case so receivers that understand the extended syntax
        /// can decode the original UTF-8 bytes.
        static func requiresExtendedFilename(_ value: String) -> Bool {
            for scalar in value.unicodeScalars {
                if scalar.value > 0x7F { return true }
            }
            return false
        }

        /// Builds the RFC 5987 `value-chars` representation of the filename:
        /// each byte that is not in the unreserved set gets percent-encoded.
        static func rfc5987EncodedFilename(_ value: String) -> String {
            var encoded = ""
            for byte in value.utf8 {
                if Self.isRFC5987Unreserved(byte) {
                    encoded.append(Character(UnicodeScalar(byte)))
                } else {
                    encoded += percentEscape(UInt32(byte))
                }
            }
            return encoded
        }

        /// Produces the ASCII fallback that goes in the legacy `filename`
        /// parameter. Non-ASCII scalars collapse to `_` so the parameter
        /// survives intermediaries that strip the extended `filename*`
        /// counterpart, while CR/LF/quote/backslash continue to use the
        /// existing percent-encoded escapes.
        static func asciiFallbackFilename(_ value: String) -> String {
            var sanitized = ""
            for scalar in value.unicodeScalars {
                if scalar.value > 0x7F {
                    sanitized.append("_")
                } else {
                    sanitized.unicodeScalars.append(scalar)
                }
            }
            return escapedHeaderParameter(sanitized)
        }

        private static func isRFC5987Unreserved(_ byte: UInt8) -> Bool {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
                return true
            case 0x21, 0x23, 0x24, 0x26, 0x2B, 0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E:
                return true
            default:
                return false
            }
        }

        private static func escapedHeaderParameter(_ value: String) -> String {
            var escaped = ""
            escaped.reserveCapacity(value.utf8.count)

            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 0x22:
                    escaped += "%22"
                case 0x5C:
                    escaped += "%5C"
                case 0x0A:
                    escaped += "%0A"
                case 0x0D:
                    escaped += "%0D"
                case 0x00...0x1F, 0x7F:
                    escaped += percentEscape(scalar.value)
                default:
                    escaped.unicodeScalars.append(scalar)
                }
            }

            return escaped
        }

        private static func escapedHeaderValue(_ value: String) -> String {
            var escaped = ""
            escaped.reserveCapacity(value.utf8.count)

            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 0x0A:
                    escaped += "%0A"
                case 0x0D:
                    escaped += "%0D"
                case 0x00...0x1F, 0x7F:
                    escaped += percentEscape(scalar.value)
                default:
                    escaped.unicodeScalars.append(scalar)
                }
            }

            return escaped
        }

        private static func percentEscape(_ value: UInt32) -> String {
            let hex = String(value, radix: 16, uppercase: true)
            return "%" + String(repeating: "0", count: max(0, 2 - hex.count)) + hex
        }
    }

    enum Source: Sendable {
        case data(Data)
        case file(URL)
    }
}
