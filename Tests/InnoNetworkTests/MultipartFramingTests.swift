import Foundation
import Testing

@testable import InnoNetwork

@Suite("Multipart framing invariants")
struct MultipartFramingTests {
    private let type = "multipart/mixed; boundary=boundary"

    @Test func everyChunkSplitPreservesFraming() async throws {
        let payload = Data("prefix--boundary\r\nsuffix".utf8) + Data([0, 255, 13])
        for padding in ["", " \t"] {
            let wire =
                Data("preamble\r\n--boundary\(padding)\r\nX-Part: one\r\n\r\n".utf8)
                + payload + Data("\r\n--boundary\(padding)\r\n\r\n\r\n--boundary--\(padding)\r\nepilogue".utf8)
            let expected = [
                MultipartPart(headers: ["X-Part": "one"], data: payload), MultipartPart(headers: [:], data: Data()),
            ]
            #expect(try MultipartResponseDecoder().decode(wire, contentType: type) == expected)
            for split in 0...wire.count {
                #expect(
                    try await collect([Data(wire.prefix(split)), Data(wire.dropFirst(split))]) == expected,
                    "split \(split), padding \(padding.debugDescription)")
            }
            #expect(try await collect(wire.map { Data([$0]) }) == expected)
            // Deterministic irregular partitions exercise more than a single split.
            for seed in 1...8 {
                var state = UInt64(seed)
                var chunks: [Data] = []
                var start = 0
                while start < wire.count {
                    state = state &* 6364136223846793005 &+ 1
                    let end = min(wire.count, start + Int(state % 19) + 1)
                    chunks.append(Data(wire[start..<end]))
                    start = end
                }
                #expect(try await collect(chunks) == expected)
            }
        }
    }

    @Test func largeBodyIsNotCountedAsHeaders() async throws {
        let payload = Data(repeating: 65, count: 2 * 1024 * 1024)
        let wire = Data("--boundary\r\nX: y\r\n\r\n".utf8) + payload + Data("\r\n--boundary--".utf8)
        let expected = [MultipartPart(headers: ["X": "y"], data: payload)]
        #expect(try await collect([wire]) == expected)
        #expect(try MultipartResponseDecoder().decode(wire, contentType: type) == expected)
    }

    @Test func emptyHeadersAndLFCompatibility() async throws {
        for line in ["\r\n", "\n"] {
            let wire = Data("--boundary\(line)\(line)hello\(line)--boundary--".utf8)
            let expected = [MultipartPart(headers: [:], data: Data("hello".utf8))]
            #expect(try MultipartResponseDecoder().decode(wire, contentType: type) == expected)
            #expect(try await collect(wire.map { Data([$0]) }) == expected)
        }
    }

    @Test func unterminatedAndOversizedHeadersFail() async throws {
        for wire in [
            Data("--boundary\r\nX: y\r\n\r\nhello".utf8),
            Data("--boundary\r\nX: ".utf8) + Data(repeating: 65, count: 1024 * 1024 + 1)
                + Data("\r\n\r\nbody\r\n--boundary--".utf8),
        ] {
            await #expect(throws: NetworkError.self) { try await collect([wire]) }
        }
    }

    private func collect(_ chunks: [Data]) async throws -> [MultipartPart] {
        let input = AsyncStream<Data> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        var parts: [MultipartPart] = []
        var headers: [String: String] = [:]
        var body = Data()
        for try await event in MultipartStreamingResponseDecoder().decode(input, contentType: type) {
            switch event {
            case .partStarted(let fields):
                headers = fields
                body = Data()
            case .bodyChunk(let bytes): body.append(bytes)
            case .partEnded: parts.append(.init(headers: headers, data: body))
            }
        }
        return parts
    }
}
