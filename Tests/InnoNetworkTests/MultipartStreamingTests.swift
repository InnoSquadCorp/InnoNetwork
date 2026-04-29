import Foundation
@_spi(GeneratedClientSupport) import InnoNetwork
import Testing

@testable import InnoNetwork

@Suite("Multipart Streaming Tests")
struct MultipartStreamingTests {

    @Test("writeEncodedData produces the same bytes as encode()")
    func writeMatchesEncodeForDataParts() throws {
        var formData = MultipartFormData(boundary: "fixed-boundary")
        formData.append("alice", name: "user")
        formData.append(
            Data("payload-bytes".utf8), name: "blob", fileName: "blob.bin", mimeType: "application/octet-stream")

        let inMemory = formData.encode()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "multipart-stream-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try formData.writeEncodedData(to: url)

        let onDisk = try Data(contentsOf: url)
        #expect(onDisk == inMemory)
    }

    @Test("Multipart header parameters escape quotes and CRLF")
    func headerParametersEscapeUnsafeCharacters() throws {
        var formData = MultipartFormData(boundary: "escape-boundary")
        formData.append(
            Data("payload".utf8),
            name: "field\"\r\nInjected-Header: yes\\",
            fileName: "avatar\"\r\nInjected-File: yes\\.png",
            mimeType: "text/plain\r\nInjected-Mime: yes"
        )

        let encoded = try #require(String(data: formData.encode(), encoding: .utf8))
        #expect(encoded.contains(#"name="field%22%0D%0AInjected-Header: yes%5C""#))
        #expect(encoded.contains(#"filename="avatar%22%0D%0AInjected-File: yes%5C.png""#))
        #expect(encoded.contains("Content-Type: text/plain%0D%0AInjected-Mime: yes"))
        #expect(!encoded.contains("\r\nInjected-Header: yes"))
        #expect(!encoded.contains("\r\nInjected-File: yes"))
        #expect(!encoded.contains("\r\nInjected-Mime: yes"))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "multipart-escape-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try formData.writeEncodedData(to: url)

        let onDisk = try #require(String(data: try Data(contentsOf: url), encoding: .utf8))
        #expect(onDisk == encoded)
    }

    @Test("Custom multipart boundary is sanitized before headers and delimiters")
    func customBoundarySanitizesUnsafeCharacters() throws {
        var formData = MultipartFormData(boundary: "safe\r\nInjected: yes")
        formData.append("value", name: "field")

        #expect(!formData.boundary.contains("\r"))
        #expect(!formData.boundary.contains("\n"))
        #expect(formData.boundary.count <= 70)
        #expect(!formData.contentTypeHeader.contains("\r\nInjected"))

        let encoded = try #require(String(data: formData.encode(), encoding: .utf8))
        #expect(encoded.contains("--\(formData.boundary)\r\n"))
        #expect(!encoded.contains("\r\nInjected"))
    }

    @Test("writeEncodedData streams a file part without loading it whole")
    func writeStreamsFileParts() async throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "multipart-source-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        // Write a 256 KiB file so the streaming path runs through multiple
        // 64 KiB chunks; the assertion just compares byte-for-byte equality.
        let payload = Data(repeating: 0x41, count: 256 * 1024)
        try payload.write(to: sourceURL)

        var formData = MultipartFormData(boundary: "stream-boundary")
        try await formData.appendFile(at: sourceURL, name: "file", mimeType: "application/octet-stream")

        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "multipart-out-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try formData.writeEncodedData(to: outURL)

        let onDisk = try Data(contentsOf: outURL)
        // The encoded body must contain the original payload verbatim.
        #expect(onDisk.range(of: payload) != nil)
        // Boundary delimiters must wrap the part on both sides.
        #expect(String(data: onDisk, encoding: .utf8)?.contains("--stream-boundary") == true)
        #expect(String(data: onDisk, encoding: .utf8)?.contains("--stream-boundary--") == true)
    }

    @Test("Async appendFile does not read the source file at append time")
    func asyncAppendFileDefersRead() async throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "multipart-defer-\(UUID().uuidString).bin")
        try Data("hello".utf8).write(to: sourceURL)

        var formData = MultipartFormData(boundary: "defer-boundary")
        try await formData.appendFile(at: sourceURL, name: "file", mimeType: "text/plain")

        // Delete the source before encoding — the async appendFile path
        // should have stored only the URL, not a Data copy. encode() will
        // therefore observe the missing file and skip the entire part, but
        // writeEncodedData should surface the read failure as a thrown error.
        try FileManager.default.removeItem(at: sourceURL)

        let encoded = String(data: formData.encode(), encoding: .utf8) ?? ""
        #expect(encoded == "--defer-boundary--\r\n")
        #expect(!encoded.contains("name=\"file\""))

        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "multipart-defer-out-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: outURL) }
        #expect(throws: (any Error).self) {
            try formData.writeEncodedData(to: outURL)
        }
    }

    @Test("Existing append(Data:name:) APIs still produce identical encode() output")
    @MainActor
    func dataAppendKeepsEncodeOutputStable() {
        var formData = MultipartFormData(boundary: "compat-boundary")
        formData.append("Alice", name: "user")
        formData.append(42, name: "count")
        formData.append(true, name: "active")

        let encoded = formData.encode()
        let asString = String(data: encoded, encoding: .utf8) ?? ""
        #expect(asString.contains("name=\"user\""))
        #expect(asString.contains("Alice"))
        #expect(asString.contains("name=\"count\""))
        #expect(asString.contains("42"))
        #expect(asString.contains("name=\"active\""))
        #expect(asString.contains("true"))
        #expect(asString.contains("--compat-boundary--"))
    }

    // MARK: - estimatedEncodedSize

    @Test("estimatedEncodedSize matches encode().count for data-only parts")
    func estimatedSizeMatchesEncodeForDataParts() {
        var formData = MultipartFormData(boundary: "size-boundary")
        formData.append("Alice", name: "user")
        formData.append(
            Data(repeating: 0xAB, count: 1024), name: "blob", fileName: "blob.bin", mimeType: "application/octet-stream"
        )

        // estimatedEncodedSize should not be expensive (no bytes are read from
        // the data source twice) but must match the actual encoded length.
        #expect(Int64(formData.encode().count) == formData.estimatedEncodedSize)
    }

    @Test("estimatedEncodedSize accounts for file parts via FileManager attributes")
    func estimatedSizeIncludesFileBytes() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("estimated-\(UUID().uuidString).bin")
        let payload = Data(repeating: 0xCD, count: 4096)
        try payload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var formData = MultipartFormData(boundary: "size-file-boundary")
        try await formData.appendFile(at: fileURL, name: "doc")

        // Encoder may stream the file at encode() time, so we compare the
        // estimator against the streaming-encode count to avoid loading the
        // file twice in the assertion.
        let streamedURL = tempDir.appendingPathComponent("written-\(UUID().uuidString).bin")
        try formData.writeEncodedData(to: streamedURL)
        defer { try? FileManager.default.removeItem(at: streamedURL) }
        let streamedSize = try Data(contentsOf: streamedURL).count

        #expect(Int64(streamedSize) == formData.estimatedEncodedSize)
    }
}


// MARK: - MultipartUploadStrategy

@Suite("Multipart Upload Strategy Tests")
struct MultipartUploadStrategyTests {

    private struct InMemoryUpload: MultipartAPIDefinition {
        typealias APIResponse = EmptyResponse
        let multipartFormData: MultipartFormData
        var method: HTTPMethod { .post }
        var path: String { "/upload" }
        // Default uploadStrategy is .inMemory; explicit for clarity.
        var uploadStrategy: MultipartUploadStrategy { .inMemory }
    }

    private struct AlwaysStreamUpload: MultipartAPIDefinition {
        typealias APIResponse = EmptyResponse
        let multipartFormData: MultipartFormData
        var method: HTTPMethod { .post }
        var path: String { "/upload" }
        var uploadStrategy: MultipartUploadStrategy { .alwaysStream }
    }

    private struct ThresholdUpload: MultipartAPIDefinition {
        typealias APIResponse = EmptyResponse
        let multipartFormData: MultipartFormData
        let threshold: Int64
        var method: HTTPMethod { .post }
        var path: String { "/upload" }
        var uploadStrategy: MultipartUploadStrategy { .streamingThreshold(bytes: threshold) }
    }

    private static func makeFormData() -> MultipartFormData {
        var formData = MultipartFormData(boundary: "strategy-boundary")
        formData.append("Alice", name: "user")
        return formData
    }

    @Test("Default .inMemory strategy produces RequestPayload.data")
    func inMemoryProducesData() throws {
        let executable = MultipartSingleRequestExecutable(base: InMemoryUpload(multipartFormData: Self.makeFormData()))
        let payload = try executable.makePayload()
        switch payload {
        case .data: break
        default: Issue.record("Expected .data for .inMemory strategy, got \(payload)")
        }
    }

    @Test(".alwaysStream produces RequestPayload.temporaryFileURL pointing at a writable temp file")
    func alwaysStreamProducesFileURL() throws {
        let executable = MultipartSingleRequestExecutable(
            base: AlwaysStreamUpload(multipartFormData: Self.makeFormData()))
        let payload = try executable.makePayload()
        switch payload {
        case .temporaryFileURL(let url, let contentType):
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(contentType.hasPrefix("multipart/form-data; boundary="))
            try? FileManager.default.removeItem(at: url)
        default:
            Issue.record("Expected .temporaryFileURL for .alwaysStream strategy, got \(payload)")
        }
    }

    @Test(".streamingThreshold uses .data when body is below the threshold")
    func thresholdBelowKeepsInMemory() throws {
        let executable = MultipartSingleRequestExecutable(
            base: ThresholdUpload(
                multipartFormData: Self.makeFormData(),
                threshold: 1_000_000
            )
        )
        let payload = try executable.makePayload()
        switch payload {
        case .data: break
        default: Issue.record("Expected .data when below threshold, got \(payload)")
        }
    }

    @Test(".streamingThreshold switches to .temporaryFileURL when body exceeds the threshold")
    func thresholdAboveStreamsToDisk() throws {
        let executable = MultipartSingleRequestExecutable(
            base: ThresholdUpload(
                multipartFormData: Self.makeFormData(),
                threshold: 0  // any non-trivial body exceeds zero
            )
        )
        let payload = try executable.makePayload()
        switch payload {
        case .temporaryFileURL(let url, _):
            #expect(FileManager.default.fileExists(atPath: url.path))
            try? FileManager.default.removeItem(at: url)
        default:
            Issue.record("Expected .temporaryFileURL above threshold, got \(payload)")
        }
    }
}
