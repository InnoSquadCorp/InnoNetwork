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


@Suite("Multipart Streaming Response Decoder Tests")
struct MultipartStreamingResponseDecoderTests {

    @Test("Streaming decoder emits part lifecycle events across chunk boundaries")
    func emitsLifecycleEventsAcrossChunkBoundaries() async throws {
        let chunks = [
            "--bo".data(using: .utf8)!,
            "undary\r\nContent-Type: text/plain\r\nX-Part: one\r\n\r\nhel".data(using: .utf8)!,
            "lo\r\n--boundary--\r\n".data(using: .utf8)!,
        ]

        let events = try await collectStreamingEvents(chunks)

        #expect(events.first == .partStarted(headers: ["Content-Type": "text/plain", "X-Part": "one"]))
        #expect(events.last == .partEnded)
        let body = events.compactMap { event -> Data? in
            if case .bodyChunk(let data) = event { return data }
            return nil
        }.reduce(Data(), +)
        #expect(String(data: body, encoding: .utf8) == "hello")
    }

    @Test("Boundary-like bytes inside payload are preserved")
    func boundaryLikeBytesInsidePayloadArePreserved() async throws {
        let body = """
            --boundary\r
            Content-Type: text/plain\r
            \r
            payload --boundary still payload\r
            --boundary--\r

            """
        let events = try await collectStreamingEvents([Data(body.utf8)])
        let data = events.compactMap { event -> Data? in
            if case .bodyChunk(let data) = event { return data }
            return nil
        }.reduce(Data(), +)

        #expect(String(data: data, encoding: .utf8) == "payload --boundary still payload")
    }

    @Test("Closing boundary marker may be split after delimiter bytes")
    func closingBoundaryMarkerSplitAfterDelimiter() async throws {
        let chunks = [
            Data("--boundary\r\nContent-Type: text/plain\r\n\r\nhello\r\n--boundary".utf8),
            Data("--\r\n".utf8),
        ]

        let events = try await collectStreamingEvents(chunks)

        #expect(events.first == .partStarted(headers: ["Content-Type": "text/plain"]))
        #expect(events.last == .partEnded)
        let body = events.compactMap { event -> Data? in
            if case .bodyChunk(let data) = event { return data }
            return nil
        }.reduce(Data(), +)
        #expect(String(data: body, encoding: .utf8) == "hello")
    }

    @Test("Missing closing boundary fails the stream")
    func missingClosingBoundaryFails() async {
        let body = Data("--boundary\r\nContent-Type: text/plain\r\n\r\nhello".utf8)

        await #expect(throws: NetworkError.self) {
            _ = try await collectStreamingEvents([body])
        }
    }

    @Test("Unbounded part headers fail before exhausting memory")
    func unboundedPartHeadersThrow() async {
        // Open the first part normally, then keep streaming header bytes
        // without ever reaching the `\r\n\r\n` separator. The decoder should
        // bail out once the buffered header region exceeds 1 MiB.
        var chunks: [Data] = [Data("--boundary\r\nX-Filler: ".utf8)]
        let chunk = Data(repeating: UInt8(ascii: "A"), count: 64 * 1024)
        // 18 × 64 KiB = ~1.1 MiB of header bytes — comfortably past the cap.
        for _ in 0..<18 {
            chunks.append(chunk)
        }
        await #expect(throws: NetworkError.self) {
            _ = try await collectStreamingEvents(chunks)
        }
    }

    private func collectStreamingEvents(_ chunks: [Data]) async throws -> [MultipartStreamingEvent] {
        let stream = AsyncStream<Data> { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
        let decoder = MultipartStreamingResponseDecoder()
        var events: [MultipartStreamingEvent] = []
        for try await event in decoder.decode(stream, contentType: "multipart/mixed; boundary=boundary") {
            events.append(event)
        }
        return events
    }
}
