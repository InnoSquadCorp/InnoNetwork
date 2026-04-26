import Foundation
import Testing
@testable import InnoNetwork


private struct LineCounterStream: StreamingAPIDefinition {
    typealias Output = String

    var method: HTTPMethod { .get }
    var path: String { "/events" }

    func decode(line: String) throws -> String? {
        guard !line.isEmpty else { return nil }
        return line
    }
}


@Suite("Streaming API Definition Tests")
struct StreamingAPIDefinitionTests {

    @Test("stream() throws when the URL session does not implement bytes()")
    func streamUnsupportedTransportThrows() async throws {
        let mockSession = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        let stream = client.stream(LineCounterStream())
        var iterator = stream.makeAsyncIterator()
        await #expect(throws: NetworkError.self) {
            _ = try await iterator.next()
        }
    }

    @Test("stream() decode(line:) returning nil filters lines")
    func decodeNilFiltersLines() throws {
        let definition = LineCounterStream()

        // Empty line → nil (filtered)
        #expect(try definition.decode(line: "") == nil)
        // Non-empty → echoed
        #expect(try definition.decode(line: "data: ping") == "data: ping")
    }
}
