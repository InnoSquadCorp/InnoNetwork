import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

@Suite("VCR URLSession Test Support")
struct VCRURLSessionTests {

    private struct RawDataEndpoint: APIDefinition {
        var sessionAuthentication: SessionAuthentication { .anonymous }
        typealias Parameter = EmptyParameter
        typealias APIResponse = Data
        var method: HTTPMethod { .get }
        var path: String { "/vcr" }

        var transport: TransportPolicy<Data> {
            .custom(encoding: .json(defaultRequestEncoder)) { data, _ in data }
        }
    }

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

    @Test("mutating redaction names remains case-insensitive in serialized cassettes")
    func mutatedRedactionNamesRemainCaseInsensitive() async throws {
        var policy = VCRRedactionPolicy()
        policy.sensitiveHeaderNames = ["X-Custom-Secret"]
        policy.sensitiveQueryItemNames.insert("Access_Token")
        #expect(policy.sensitiveHeaderNames == ["x-custom-secret"])
        #expect(policy.sensitiveQueryItemNames.contains("access_token"))

        let backing = MockURLSession()
        backing.mockResponse = HTTPURLResponse(
            url: URL(string: "https://api.example.com/resource")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["X-Custom-Secret": "response-secret"]
        )!
        let vcr = VCRURLSession(mode: .record, recordingSession: backing, redactionPolicy: policy)
        var request = URLRequest(url: URL(string: "https://api.example.com/resource?access_token=query-secret")!)
        request.setValue("request-secret", forHTTPHeaderField: "x-custom-secret")
        _ = try await vcr.data(for: request)

        let serialized = String(decoding: try JSONEncoder().encode(vcr.cassette), as: UTF8.self)
        #expect(!serialized.contains("request-secret"))
        #expect(!serialized.contains("response-secret"))
        #expect(!serialized.contains("query-secret"))
        let interaction = try #require(vcr.cassette.interactions.first)
        #expect(interaction.request.headers["x-custom-secret"] == "<redacted>")
        #expect(interaction.response.headers["x-custom-secret"] == "<redacted>")
    }

    @Test("bounded streaming fails closed before VCR record transport")
    func boundedStreamingRejectsVCRRecordMode() async throws {
        let backing = MockURLSession()
        backing.setMockResponse(statusCode: 200, data: Data("unused".utf8))
        let vcr = VCRURLSession(mode: .record, recordingSession: backing)
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://api.example.com")!),
            session: vcr
        )

        do {
            _ = try await client.request(RawDataEndpoint())
            Issue.record("Expected bounded streaming to reject VCR record mode")
        } catch let error {
            guard case .configuration(reason: .invalidRequest) = error else {
                Issue.record("Expected invalid-request configuration, got \(error)")
                return
            }
        }

        #expect(backing.capturedRequest == nil)
        #expect(vcr.cassette.interactions.isEmpty)
    }

    @Test("recording removes URL credentials and fragments without changing transport")
    func recordingRemovesURLIdentitySecrets() async throws {
        let url = try #require(
            URL(
                string:
                    "https://fixture-user:fixture-password@api.example.com/a%2Fb?keep=1&token=query-secret#fragment-secret"
            )
        )
        let backing = MockURLSession()
        backing.setMockResponse(statusCode: 200, data: Data("ok".utf8))
        let recorder = VCRURLSession(mode: .record, recordingSession: backing)
        _ = try await recorder.data(for: URLRequest(url: url))

        #expect(backing.capturedRequest?.url == url)
        let recorded = try #require(recorder.cassette.interactions.first)
        #expect(recorded.request.url == "https://api.example.com/a%2Fb?keep=1&token=%3Credacted%3E")
        let serialized = String(decoding: try JSONEncoder().encode(recorder.cassette), as: UTF8.self)
        for secret in ["fixture-user", "fixture-password", "fragment-secret", "query-secret"] {
            #expect(!serialized.contains(secret))
        }

        let replay = VCRURLSession(cassette: recorder.cassette, mode: .replay)
        let (data, _) = try await replay.data(for: URLRequest(url: url))
        #expect(data == Data("ok".utf8))
    }

    @Test("legacy cassette URLs migrate in memory and keep sequential replay")
    func legacyCassetteURLsMigrateWithoutSkipping() async throws {
        let legacy = VCRCassette(interactions: [
            VCRInteraction(
                request: VCRRequest(
                    method: "GET", url: "https://old-user:old-password@api.example.com/item#old-fragment", headers: [:]
                ),
                response: VCRResponse(statusCode: 200, body: Data("first".utf8))
            ),
            VCRInteraction(
                request: VCRRequest(method: "GET", url: "https://api.example.com/item#other-fragment", headers: [:]),
                response: VCRResponse(statusCode: 200, body: Data("second".utf8))
            ),
        ])
        let replay = VCRURLSession(cassette: legacy, mode: .replay)
        let serialized = String(decoding: try JSONEncoder().encode(replay.cassette), as: UTF8.self)
        for secret in ["old-user", "old-password", "old-fragment", "other-fragment"] {
            #expect(!serialized.contains(secret))
        }
        #expect(legacy.interactions[0].request.url.contains("old-password"))
        let request = URLRequest(url: try #require(URL(string: "https://api.example.com/item")))
        let (first, _) = try await replay.data(for: request)
        let (second, _) = try await replay.data(for: request)
        #expect(first == Data("first".utf8))
        #expect(second == Data("second".utf8))
        await #expect(throws: NetworkError.self) { _ = try await replay.data(for: request) }
    }

    @Test("replay mismatch diagnostics never expose URL credentials or fragments")
    func replayMismatchRedactsURLIdentitySecrets() async throws {
        let replay = VCRURLSession(mode: .replay)
        let request = URLRequest(
            url: try #require(
                URL(string: "https://fixture-user:fixture-password@api.example.com/missing#fragment-secret"))
        )
        do {
            _ = try await replay.data(for: request)
            Issue.record("Expected a cassette mismatch")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("https://api.example.com/missing"))
            for secret in ["fixture-user", "fixture-password", "fragment-secret"] {
                #expect(!message.contains(secret))
            }
        }
    }

    @Test("resaving a migrated cassette sanitizes URLs without rewriting the source file")
    func migratedCassetteDiskRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vcr-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("original.json")
        let migratedURL = directory.appendingPathComponent("migrated.json")
        let original = VCRCassette(interactions: [
            VCRInteraction(
                request: VCRRequest(method: "POST", url: "https://old:secret@api.example.com/a#private", headers: [:]),
                response: VCRResponse(statusCode: 202, body: Data("caller-reviewed-body".utf8))
            )
        ])
        try original.write(to: originalURL)
        let originalBytes = try Data(contentsOf: originalURL)
        let session = VCRURLSession(cassette: try VCRCassette.load(from: originalURL), mode: .replay)
        try session.cassette.write(to: migratedURL)
        let migrated = try VCRCassette.load(from: migratedURL)
        #expect(try Data(contentsOf: originalURL) == originalBytes)
        #expect(migrated.interactions.first?.request.url == "https://api.example.com/a")
        #expect(migrated.interactions.first?.response == original.interactions.first?.response)
        #expect(VCRURLSession(cassette: migrated, mode: .replay).cassette == migrated)
    }

    @Test("URL privacy removal is independent of configured query redaction")
    func customQueryPolicyKeepsPublicURLIdentity() async throws {
        let url = try #require(URL(string: "https://name:password@[::1]:8443/a%2Fb?keep=a%26b&token=public#private"))
        let backing = MockURLSession()
        backing.setMockResponse(statusCode: 200, data: Data())
        let recorder = VCRURLSession(
            mode: .record, recordingSession: backing,
            redactionPolicy: VCRRedactionPolicy(sensitiveQueryItemNames: [])
        )
        _ = try await recorder.data(for: URLRequest(url: url))
        #expect(
            recorder.cassette.interactions.first?.request.url
                == "https://[::1]:8443/a%2Fb?keep=a%26b&token=public"
        )
    }

    @Test("bounded streaming replays an already-buffered VCR cassette")
    func boundedStreamingAllowsVCRReplayMode() async throws {
        let baseURL = URL(string: "https://api.example.com")!
        let payload = Data("replayed".utf8)
        let backing = MockURLSession()
        backing.setMockResponse(statusCode: 200, data: payload)
        let recorder = VCRURLSession(mode: .record, recordingSession: backing)
        let recordClient = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                networkMonitor: nil,
                responseBodyBufferingPolicy: .buffered(maxBytes: 5 * 1_024 * 1_024)
            ),
            session: recorder
        )
        _ = try await recordClient.request(RawDataEndpoint())

        let replay = VCRURLSession(cassette: recorder.cassette, mode: .replay)
        let replayClient = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: baseURL),
            session: replay
        )

        let received = try await replayClient.request(RawDataEndpoint())
        #expect(received == payload)
    }

    @Test("VCR replay preserves the safe-default response ceiling")
    func vcrReplayPreservesSafeDefaultLimit() async throws {
        let baseURL = URL(string: "https://api.example.com")!
        let limit: Int64 = 5 * 1_024 * 1_024
        let payload = Data(repeating: 0xA5, count: Int(limit + 1))
        let backing = MockURLSession()
        backing.setMockResponse(statusCode: 200, data: payload)
        let recorder = VCRURLSession(mode: .record, recordingSession: backing)
        let recordClient = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                networkMonitor: nil,
                responseBodyBufferingPolicy: .buffered(maxBytes: nil)
            ),
            session: recorder
        )
        _ = try await recordClient.request(RawDataEndpoint())

        let replay = VCRURLSession(cassette: recorder.cassette, mode: .replay)
        let replayClient = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: baseURL),
            session: replay
        )

        do {
            _ = try await replayClient.request(RawDataEndpoint())
            Issue.record("Expected the safe-default response ceiling")
        } catch let error {
            guard
                case .underlying(let underlying, _) = error,
                underlying.code == NetworkErrorCode.responseBodyLimitExceeded.rawValue
            else {
                Issue.record("Expected responseBodyLimitExceeded, got \(error)")
                return
            }
            #expect(underlying.message.contains("\(limit)"))
            #expect(underlying.message.contains("\(payload.count)"))
        }
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
