import Foundation
import Testing

@testable import InnoNetwork

@Suite("Multipart response decoder")
struct MultipartResponseDecoderTests {
    @Test("Decodes multipart response parts")
    func decodesParts() throws {
        let body = """
            --boundary
            Content-Type: application/json
            X-Part: one

            {"id":1}
            --boundary
            Content-Type: text/plain

            hello
            --boundary--

            """
        let parts = try MultipartResponseDecoder().decode(
            Data(body.utf8),
            contentType: "multipart/mixed; boundary=boundary"
        )
        #expect(parts.count == 2)
        #expect(parts[0].headers["Content-Type"] == "application/json")
        #expect(String(data: parts[1].data, encoding: .utf8) == "hello")
    }

    @Test("Preserves binary part data")
    func preservesBinaryPartData() throws {
        let binary = Data([0x00, 0xFF, 0x01, 0x02])
        var body = Data()
        body.append(Data("--boundary\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(binary)
        body.append(Data("\r\n--boundary--\r\n".utf8))

        let parts = try MultipartResponseDecoder().decode(
            body,
            contentType: "multipart/mixed; boundary=boundary"
        )

        #expect(parts.count == 1)
        #expect(parts[0].headers["Content-Type"] == "application/octet-stream")
        #expect(parts[0].data == binary)
    }

    @Test("Preserves boundary bytes inside part payload")
    func preservesBoundaryBytesInsidePayload() throws {
        let body = """
            --boundary
            Content-Type: text/plain

            embedded --boundary bytes are not delimiters
            --boundary--

            """

        let parts = try MultipartResponseDecoder().decode(
            Data(body.utf8),
            contentType: "multipart/mixed; boundary=boundary"
        )

        #expect(parts.count == 1)
        #expect(
            String(data: parts[0].data, encoding: .utf8)
                == "embedded --boundary bytes are not delimiters")
    }

    @Test("Throws when boundary is missing")
    func missingBoundaryThrows() {
        #expect(throws: NetworkError.self) {
            try MultipartResponseDecoder().decode(Data(), contentType: "multipart/mixed")
        }
    }
}
