import Foundation
import Testing

@testable import InnoNetwork

@Suite("Decoding Interceptor Tests")
struct DecodingInterceptorTests {

    private struct EnvelopeBody: Codable, Sendable, Equatable {
        let value: Int
    }

    private struct GetEnvelope: APIDefinition {
        typealias Parameter = EmptyParameter
        typealias APIResponse = EnvelopeBody
        var method: HTTPMethod { .get }
        var path: String { "/envelope" }
    }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _willDecode = 0
        private var _didDecode = 0

        var willDecode: Int { lock.withLock { _willDecode } }
        var didDecode: Int { lock.withLock { _didDecode } }

        func incrementWill() { lock.withLock { _willDecode += 1 } }
        func incrementDid() { lock.withLock { _didDecode += 1 } }
    }

    private struct EnvelopeUnwrapper: DecodingInterceptor {
        let counter: CallCounter
        func willDecode(data: Data, response: Response) async throws -> Data {
            counter.incrementWill()
            // Strip a `{ "data": <inner> }` envelope so the decoder sees
            // the inner object directly.
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let inner = object?["data"] as Any? ?? object as Any
            return try JSONSerialization.data(withJSONObject: inner as Any)
        }

        func didDecode<APIResponse>(
            _ value: APIResponse,
            response: Response
        ) async throws -> APIResponse where APIResponse: Sendable {
            counter.incrementDid()
            return value
        }
    }

    @Test("willDecode unwraps envelope and didDecode observes typed value")
    func envelopeUnwrap() async throws {
        let payload = #"{"data":{"value":42}}"#.data(using: .utf8)!
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: payload)

        let counter = CallCounter()
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            networkMonitor: nil,
            decodingInterceptors: [EnvelopeUnwrapper(counter: counter)]
        )
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        let received = try await client.request(GetEnvelope())
        #expect(received == EnvelopeBody(value: 42))
        #expect(counter.willDecode == 1)
        #expect(counter.didDecode == 1)
    }

    private struct ThrowingInterceptor: DecodingInterceptor {
        struct Failure: Error, Equatable {}
        func willDecode(data: Data, response: Response) async throws -> Data {
            throw Failure()
        }
    }

    @Test("Throwing willDecode aborts the request")
    func throwingWillDecodeAborts() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: #"{"value":1}"#.data(using: .utf8)!)

        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            networkMonitor: nil,
            decodingInterceptors: [ThrowingInterceptor()]
        )
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        await #expect(throws: Error.self) {
            _ = try await client.request(GetEnvelope())
        }
    }

    @Test("No interceptors keeps existing decode behaviour")
    func noInterceptorsParity() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: #"{"value":7}"#.data(using: .utf8)!)

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        let received = try await client.request(GetEnvelope())
        #expect(received == EnvelopeBody(value: 7))
    }
}
