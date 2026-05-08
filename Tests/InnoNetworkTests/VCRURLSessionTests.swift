import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

@Suite("VCR URLSession Test Support")
struct VCRURLSessionTests {

    @Test("record mode stores a redacted deterministic cassette")
    func recordModeStoresRedactedCassette() async throws {
        let backing = MockURLSession()
        backing.mockData = Data("recorded".utf8)
        backing.mockResponse = HTTPURLResponse(
            url: URL(string: "https://api.example.com/users?token=secret")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Set-Cookie": "sid=secret", "X-Trace": "abc"]
        )!
        let vcr = VCRURLSession(mode: .record, recordingSession: backing)
        var request = URLRequest(url: URL(string: "https://api.example.com/users?token=secret&keep=1")!)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        let (data, response) = try await vcr.data(for: request)

        #expect(data == Data("recorded".utf8))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let interaction = try #require(vcr.cassette.interactions.first)
        #expect(interaction.request.url == "https://api.example.com/users?token=%3Credacted%3E&keep=1")
        #expect(interaction.request.headers["authorization"] == "<redacted>")
        #expect(interaction.response.headers["set-cookie"] == "<redacted>")
        #expect(interaction.response.headers["x-trace"] == "abc")
    }

    @Test("cassette writes and loads deterministic JSON")
    func cassetteWritesAndLoadsDeterministicJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("innonetwork-vcr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cassette.json", isDirectory: false)
        let cassette = VCRCassette(
            interactions: [
                VCRInteraction(
                    request: VCRRequest(method: "GET", url: "https://api.example.com/users", headers: [:]),
                    response: VCRResponse(statusCode: 200, body: Data("ok".utf8))
                )
            ]
        )

        try cassette.write(to: url)
        let firstWrite = try String(contentsOf: url, encoding: .utf8)
        try cassette.write(to: url)
        let secondWrite = try String(contentsOf: url, encoding: .utf8)
        let loaded = try VCRCassette.load(from: url)

        #expect(firstWrite == secondWrite)
        #expect(loaded == cassette)
    }

    @Test("replay mode returns a matching cassette response")
    func replayModeReturnsMatchingResponse() async throws {
        let request = VCRRequest(
            method: "GET",
            url: "https://api.example.com/users?token=%3Credacted%3E",
            headers: ["authorization": "<redacted>"]
        )
        let cassette = VCRCassette(
            interactions: [
                VCRInteraction(
                    request: request,
                    response: VCRResponse(
                        statusCode: 201, headers: ["Content-Type": "text/plain"], body: Data("hit".utf8))
                )
            ]
        )
        let vcr = VCRURLSession(cassette: cassette, mode: .replay)
        var urlRequest = URLRequest(url: URL(string: "https://api.example.com/users?token=secret")!)
        urlRequest.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        let (data, response) = try await vcr.data(for: urlRequest)

        #expect(data == Data("hit".utf8))
        #expect((response as? HTTPURLResponse)?.statusCode == 201)
    }

    @Test("replay mode advances through repeated matching requests")
    func replayModeAdvancesThroughRepeatedMatches() async throws {
        let request = VCRRequest(
            method: "GET",
            url: "https://api.example.com/poll",
            headers: [:]
        )
        let cassette = VCRCassette(
            interactions: [
                VCRInteraction(
                    request: request,
                    response: VCRResponse(statusCode: 200, body: Data("pending".utf8))
                ),
                VCRInteraction(
                    request: request,
                    response: VCRResponse(statusCode: 200, body: Data("done".utf8))
                ),
            ]
        )
        let vcr = VCRURLSession(cassette: cassette, mode: .replay)
        let urlRequest = URLRequest(url: URL(string: "https://api.example.com/poll")!)

        let (first, _) = try await vcr.data(for: urlRequest)
        let (second, _) = try await vcr.data(for: urlRequest)

        #expect(String(data: first, encoding: .utf8) == "pending")
        #expect(String(data: second, encoding: .utf8) == "done")
    }

    @Test("replay mode fails unmatched requests")
    func replayModeFailsUnmatchedRequests() async {
        let vcr = VCRURLSession(cassette: VCRCassette(), mode: .replay)
        let request = URLRequest(url: URL(string: "https://api.example.com/missing")!)

        await #expect(throws: NetworkError.self) {
            _ = try await vcr.data(for: request)
        }
    }
}
