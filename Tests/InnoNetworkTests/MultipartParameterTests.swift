import Foundation
import Testing

@testable import InnoNetwork

@Suite("Multipart Content-Type parameters")
struct MultipartParameterTests {
    private let body = Data("--real\r\n\r\nhello\r\n--real--\r\n".utf8)

    @Test(arguments: [
        "multipart/mixed; boundary=real",
        "multipart/mixed; note=control; boundary=real",
        #"multipart/mixed; note="x; boundary=wrong"; boundary=real"#,
        #"multipart/mixed; boundary="r\eal""#,
        #"multipart/mixed; note="x\"; boundary=wrong"; BOUNDARY="real""#,
        "multipart/mixed;\tboundary=real \t; note=last",
        "multipart/mixed;; boundary=real;",
    ])
    func quotedParametersPreserveBoundary(contentType: String) async throws {
        let parts = try MultipartResponseDecoder().decode(body, contentType: contentType)
        #expect(parts == [MultipartPart(headers: [:], data: Data("hello".utf8))])
        for size in [1, 7, body.count] {
            let sink = Sink()
            try await MultipartStreamingResponseDecoder().decode(chunks(size: size), contentType: contentType) {
                await sink.append($0)
            }
            check(await sink.events)
            var events: [MultipartStreamingEvent] = []
            for try await event in MultipartStreamingResponseDecoder().decode(
                chunks(size: size), contentType: contentType)
            {
                events.append(event)
            }
            check(events)
        }
    }

    @Test(arguments: [
        "multipart/mixed; boundary=real; BOUNDARY=wrong",
        "multipart/mixed; boundary=real; boundary=real",
        #"multipart/mixed; note="unterminated; boundary=real"#,
        #"multipart/mixed; boundary="real"junk"#,
        "multipart/mixed; boundary =real",
        "multipart/mixed; boundary= real",
        "multipart/mixed; boundary=",
        "multipart/mixed; boundary=real; note=\"bad\rvalue\"",
        "multipart/mixed; boundary=real; note=\"bad\\\nvalue\"",
        "multipart/mixed; boundary=real; invalid",
    ])
    func malformedParametersFailClosed(contentType: String) async {
        #expect(throws: NetworkError.self) { try MultipartResponseDecoder().decode(body, contentType: contentType) }
        let sink = Sink()
        await #expect(throws: NetworkError.self) {
            try await MultipartStreamingResponseDecoder().decode(chunks(size: 1), contentType: contentType) {
                await sink.append($0)
            }
        }
        #expect(await sink.events.isEmpty)
        await #expect(throws: NetworkError.self) {
            for try await _ in MultipartStreamingResponseDecoder().decode(chunks(size: 1), contentType: contentType) {}
        }
    }

    @Test func explicitOverrideDoesNotParseHeader() async throws {
        let parts = try MultipartResponseDecoder(boundary: "real").decode(body, contentType: "invalid")
        #expect(parts.count == 1)
        let sink = Sink()
        try await MultipartStreamingResponseDecoder(boundary: "real").decode(chunks(size: 1), contentType: "invalid") {
            await sink.append($0)
        }
        check(await sink.events)
    }

    private func chunks(size: Int) -> AsyncStream<Data> {
        AsyncStream { continuation in
            for start in stride(from: 0, to: body.count, by: size) {
                continuation.yield(Data(body[start..<min(start + size, body.count)]))
            }
            continuation.finish()
        }
    }

    private func check(_ events: [MultipartStreamingEvent]) {
        #expect(events.first == .partStarted(headers: [:]))
        #expect(events.filter { $0 == .partEnded }.count == 1)
        #expect(events.last == .partEnded)
        let bytes = events.reduce(into: Data()) { data, event in
            if case .bodyChunk(let chunk) = event { data.append(chunk) }
        }
        #expect(bytes == Data("hello".utf8))
    }

    private actor Sink {
        var events: [MultipartStreamingEvent] = []
        func append(_ event: MultipartStreamingEvent) { events.append(event) }
    }
}
