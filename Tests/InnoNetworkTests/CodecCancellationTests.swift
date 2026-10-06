import Foundation
import Testing

@testable import InnoNetwork

private let cancellationErrorKey = CodingUserInfoKey(rawValue: "test-cancellation")!

private func expectTypedCancellation(_ error: any Error) {
    guard case .cancelled = error as? NetworkError else {
        Issue.record("Cancellation changed to \(error)")
        return
    }
}

private struct CancellingResponse: Decodable, Sendable, HTTPEmptyResponseDecodable {
    private init() {}
    static func emptyResponseValue() -> Self { Self() }
    init(from decoder: any Decoder) throws {
        throw (decoder.userInfo[cancellationErrorKey] as? any Error) ?? CancellationError()
    }
}

@APIDefinition(method: .get, path: "/cancel-decoder", auth: .anonymous)
private struct CancellingJSONEndpoint {
    typealias APIResponse = CancellingResponse
}

@Suite("Codec cancellation normalization")
struct CodecCancellationTests {
    @Test("JSON factories distinguish cancellation from malformed input")
    func jsonCancellation() throws {
        let url = try #require(URL(string: "https://example.com"))
        let http = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let response = Response(statusCode: 200, data: Data("{}".utf8), response: http)
        let errors: [any Error] = [CancellationError(), URLError(.cancelled), NetworkError.cancelled]
        for error in errors {
            let decoder = JSONDecoder()
            decoder.userInfo[cancellationErrorKey] = error
            let factories: [AnyResponseDecoder<CancellingResponse>] = [
                .json(decoder: decoder), .jsonEmptyCapable(decoder: decoder),
                .init(strategy: .jsonAllowingEmpty(decoder)),
            ]
            for factory in factories {
                do {
                    _ = try factory.decode(data: response.data, response: response)
                    Issue.record("Expected cancellation")
                } catch { expectTypedCancellation(error) }
                do {
                    _ = try factory.decode(data: Data("invalid-json".utf8), response: response)
                    Issue.record("Expected decoding failure")
                } catch {
                    guard case .decoding = error as? NetworkError else {
                        Issue.record("Malformed JSON changed to \(error)")
                        continue
                    }
                }
            }
        }
    }

    @Test("Macro-first JSON and promoted custom endpoints keep typed cancellation")
    func clientCancellation() async throws {
        let session = MockURLSession()
        session.setMockResponse(statusCode: 200, data: Data("{}".utf8))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://example.com"), session: session)
        do {
            _ = try await client.request(CancellingJSONEndpoint())
            Issue.record("Expected cancellation")
        } catch { expectTypedCancellation(error) }
        let promoted = EndpointBuilder<EmptyResponse>.get("/promoted")
            .transport(.custom(encoding: .none) { _, _ in EmptyResponse() })
            .decoding(CancellingResponse.self)
        do {
            _ = try await client.request(promoted)
            Issue.record("Expected cancellation")
        } catch { expectTypedCancellation(error) }
        #expect(session.capturedRequestsInOrder.count == 2)
    }

    @Test("Custom buffered decode and query encoding preserve all supported cancellation representations")
    func customAndQueryCancellation() throws {
        struct Query: Encodable, Sendable {
            let error: any Error
            func encode(to encoder: any Encoder) throws { throw error }
        }
        let url = try #require(URL(string: "https://example.com"))
        let http = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let response = Response(statusCode: 200, data: Data(), response: http)
        let errors: [any Error] = [CancellationError(), URLError(.cancelled), NetworkError.cancelled]
        for error in errors {
            let custom = TransportPolicy<String>.custom(encoding: .none) { _, _ in throw error }
            do {
                _ = try custom.responseDecoder.decode(data: Data(), response: response)
                Issue.record("Expected cancellation")
            } catch { #expect(NetworkError.isCancellation(error)) }
            do {
                _ = try EncodedRequestOptions().addingQuery(Query(error: error))
                Issue.record("Expected cancellation")
            } catch { expectTypedCancellation(error) }
        }
        do {
            _ = try EncodedRequestOptions().addingQuery(Query(error: URLError(.timedOut)))
            Issue.record("Expected invalid input")
        } catch {
            guard case .configuration(reason: .invalidPayload(.encoding)) = error else {
                Issue.record("A non-cancel query failure changed to \(error)")
                return
            }
        }
    }
}
