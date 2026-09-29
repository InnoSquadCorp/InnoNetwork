import Foundation
import Testing

@testable import InnoNetwork

@Suite("Multipart incremental search")
struct MultipartScanningTests {
    @Test(arguments: ["headers", "padding", "closingPadding", "falseBoundary"])
    func tinyChunksHaveLinearSearchWork(region: String) throws {
        let spaces = Data(repeating: 32, count: 8192)
        var payload = Data("ok".utf8)
        let wire: Data
        switch region {
        case "headers": wire = Data("--b\r\nX: ".utf8) + spaces + Data("\r\n\r\nok\r\n--b--".utf8)
        case "padding": wire = Data("--b".utf8) + spaces + Data("\r\n\r\nok\r\n--b--".utf8)
        case "closingPadding": wire = Data("--b\r\n\r\nok\r\n--b--".utf8) + spaces + Data("\r\n".utf8)
        default:
            payload += Data("\r\n--b".utf8) + spaces + Data("X\r\nrest".utf8)
            wire = Data("--b\r\n\r\n".utf8) + payload + Data("\r\n--b--".utf8)
        }
        for chunkSize in [1, 7, 16384] {
            var parser = try MultipartResponseParser(boundary: "b")
            var body = Data()
            var starts = 0
            var ends = 0
            func collect(_ event: MultipartStreamingEvent) {
                switch event {
                case .partStarted: starts += 1
                case .bodyChunk(let data): body.append(data)
                case .partEnded: ends += 1
                }
            }
            for offset in stride(from: 0, to: wire.count, by: chunkSize) {
                parser.append(Data(wire[offset..<min(offset + chunkSize, wire.count)]))
                while let event = try parser.next() { collect(event) }
            }
            while let event = try parser.next(isFinal: true) { collect(event) }
            #expect(body == payload)
            #expect(starts == 1 && ends == 1)
            #if DEBUG
            #expect(parser.scannedByteCount <= wire.count * 20, "search work must not grow quadratically")
            #endif
        }
    }
}
