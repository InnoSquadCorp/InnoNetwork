import Foundation
import Testing
@testable import InnoNetwork


@Suite("Multipart Streaming Tests")
struct MultipartStreamingTests {

    @Test("writeEncodedData produces the same bytes as encode()")
    func writeMatchesEncodeForDataParts() throws {
        var formData = MultipartFormData(boundary: "fixed-boundary")
        formData.append("alice", name: "user")
        formData.append(Data("payload-bytes".utf8), name: "blob", fileName: "blob.bin", mimeType: "application/octet-stream")

        let inMemory = formData.encode()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-stream-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try formData.writeEncodedData(to: url)

        let onDisk = try Data(contentsOf: url)
        #expect(onDisk == inMemory)
    }

    @Test("writeEncodedData streams a file part without loading it whole")
    func writeStreamsFileParts() async throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-source-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        // Write a 256 KiB file so the streaming path runs through multiple
        // 64 KiB chunks; the assertion just compares byte-for-byte equality.
        let payload = Data(repeating: 0x41, count: 256 * 1024)
        try payload.write(to: sourceURL)

        var formData = MultipartFormData(boundary: "stream-boundary")
        try await formData.appendFile(at: sourceURL, name: "file", mimeType: "application/octet-stream")

        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-out-\(UUID().uuidString).bin")
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
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-defer-\(UUID().uuidString).bin")
        try Data("hello".utf8).write(to: sourceURL)

        var formData = MultipartFormData(boundary: "defer-boundary")
        try await formData.appendFile(at: sourceURL, name: "file", mimeType: "text/plain")

        // Delete the source before encoding — the async appendFile path
        // should have stored only the URL, not a Data copy. encode() will
        // therefore observe the missing file and skip the body, but
        // writeEncodedData should surface the read failure as a thrown error.
        try FileManager.default.removeItem(at: sourceURL)

        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-defer-out-\(UUID().uuidString).bin")
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
}
