import Foundation
import Testing
import os

@testable import InnoNetwork

private struct ExplicitDecoderRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = String

    var method: HTTPMethod { .get }
    var path: String { "/decoder-explicit" }

    var transport: TransportPolicy<String> {
        .custom(encoding: .query(URLQueryEncoder(), rootKey: nil)) { _, _ in
            "decoded-by-explicit-strategy"
        }
    }
}

private final class TransportAccessCounter: Sendable {
    private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)

    func recordAccess() {
        lock.withLock { $0 += 1 }
    }

    var value: Int {
        lock.withLock { $0 }
    }
}

private struct CountingTransportBodyRequest: APIDefinition {
    struct Parameter: Encodable, Sendable {
        let message: String
    }

    typealias APIResponse = Data

    let parameters: Parameter?
    let transportAccessCounter: TransportAccessCounter

    var method: HTTPMethod { .post }
    var path: String { "/transport-snapshot" }

    var transport: TransportPolicy<Data> {
        transportAccessCounter.recordAccess()
        return .custom(encoding: .json(defaultRequestEncoder)) { data, _ in data }
    }
}


@Suite("Decoder Factory Tests")
struct APIDefinitionDecoderTests {
    @Test("Request execution uses explicit transport responseDecoder")
    func explicitResponseDecoderIsUsed() async throws {
        let configuration = makeTestNetworkConfiguration(baseURL: "https://example.com")
        let session = MockURLSession()
        session.setMockResponse(statusCode: 200, data: Data("ignored".utf8))
        let client = DefaultNetworkClient(configuration: configuration, session: session)

        let result = try await client.request(ExplicitDecoderRequest())
        #expect(result == "decoded-by-explicit-strategy")
    }

    @Test("Transport policy preserves explicit responseDecoder override")
    func transportPolicyUsesExplicitDecoderOverride() throws {
        let request = ExplicitDecoderRequest()
        let httpResponse = try #require(
            HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )
        let response = Response(statusCode: 200, data: Data(), response: httpResponse)

        let result = try request.transport.responseDecoder.decode(data: Data(), response: response)
        #expect(result == "decoded-by-explicit-strategy")
    }

    @Test("Body request snapshots transport once for encoding and decoding")
    func bodyRequestSnapshotsTransportOnce() async throws {
        let configuration = makeTestNetworkConfiguration(baseURL: "https://example.com")
        let session = MockURLSession()
        let responseData = Data("decoded-response".utf8)
        session.setMockResponse(statusCode: 200, data: responseData)
        let client = DefaultNetworkClient(configuration: configuration, session: session)
        let counter = TransportAccessCounter()

        let result = try await client.request(
            CountingTransportBodyRequest(
                parameters: .init(message: "encoded-request"),
                transportAccessCounter: counter
            ))

        let requestBody = try #require(session.capturedRequest?.httpBody)
        let requestObject = try #require(
            JSONSerialization.jsonObject(with: requestBody) as? [String: String]
        )
        #expect(requestObject["message"] == "encoded-request")
        #expect(result == responseData)
        #expect(counter.value == 1)
    }
}
