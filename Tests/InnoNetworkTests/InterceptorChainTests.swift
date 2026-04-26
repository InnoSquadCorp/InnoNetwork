import Foundation
import os
import Testing
@testable import InnoNetwork


private final class TraceRecorder: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[String]>(initialState: [])

    func append(_ entry: String) {
        lock.withLock { $0.append(entry) }
    }

    var snapshot: [String] {
        lock.withLock { $0 }
    }
}


private struct HeaderStampingInterceptor: RequestInterceptor {
    let label: String
    let recorder: TraceRecorder

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        recorder.append("req:\(label)")
        var copy = urlRequest
        copy.setValue(label, forHTTPHeaderField: "X-Trace-\(label)")
        return copy
    }
}


private struct ResponseStampingInterceptor: ResponseInterceptor {
    let label: String
    let recorder: TraceRecorder

    func adapt(_ urlResponse: Response, request: URLRequest) async throws -> Response {
        recorder.append("res:\(label)")
        return urlResponse
    }
}


private struct ResponseRewritingInterceptor: ResponseInterceptor {
    let statusCode: Int
    let response: StampedTraceResponse

    func adapt(_ urlResponse: Response, request: URLRequest) async throws -> Response {
        guard let httpResponse = urlResponse.response else {
            throw NetworkError.invalidRequestConfiguration("Missing HTTPURLResponse for response rewrite.")
        }
        return Response(
            statusCode: statusCode,
            data: try JSONEncoder().encode(response),
            request: urlResponse.request,
            response: httpResponse
        )
    }
}


private struct StampedTraceRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = StampedTraceResponse

    var method: HTTPMethod { .get }
    var path: String { "/trace" }

    let endpointRequestInterceptors: [RequestInterceptor]
    let endpointResponseInterceptors: [ResponseInterceptor]

    var requestInterceptors: [RequestInterceptor] { endpointRequestInterceptors }
    var responseInterceptors: [ResponseInterceptor] { endpointResponseInterceptors }
}


private struct StampedTraceResponse: Codable, Sendable, Equatable {
    let ok: Bool
}


@Suite("Interceptor Chain Tests")
struct InterceptorChainTests {

    @Test("Session and per-request interceptors compose with onion ordering")
    func sessionAndEndpointChainsCompose() async throws {
        let recorder = TraceRecorder()
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(StampedTraceResponse(ok: true))

        let configuration = makeTestNetworkConfiguration(
            baseURL: "https://api.example.com/v1"
        )
        let configWithInterceptors = NetworkConfiguration(
            baseURL: configuration.baseURL,
            timeout: configuration.timeout,
            cachePolicy: configuration.cachePolicy,
            retryPolicy: configuration.retryPolicy,
            networkMonitor: configuration.networkMonitor,
            metricsReporter: configuration.metricsReporter,
            trustPolicy: configuration.trustPolicy,
            eventObservers: configuration.eventObservers,
            eventDeliveryPolicy: configuration.eventDeliveryPolicy,
            eventMetricsReporter: configuration.eventMetricsReporter,
            acceptableStatusCodes: configuration.acceptableStatusCodes,
            requestInterceptors: [HeaderStampingInterceptor(label: "session", recorder: recorder)],
            responseInterceptors: [ResponseStampingInterceptor(label: "session", recorder: recorder)]
        )
        let client = DefaultNetworkClient(configuration: configWithInterceptors, session: mockSession)

        let request = StampedTraceRequest(
            endpointRequestInterceptors: [HeaderStampingInterceptor(label: "endpoint", recorder: recorder)],
            endpointResponseInterceptors: [ResponseStampingInterceptor(label: "endpoint", recorder: recorder)]
        )

        _ = try await client.request(request)

        // Onion: request runs outer→inner (session before endpoint),
        // response unwinds inner→outer (endpoint before session).
        #expect(recorder.snapshot == ["req:session", "req:endpoint", "res:endpoint", "res:session"])

        // Both header stamps must reach the captured request.
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "X-Trace-session") == "session")
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "X-Trace-endpoint") == "endpoint")
    }

    @Test("Session-only interceptors run when the endpoint declares none")
    func sessionOnlyChain() async throws {
        let recorder = TraceRecorder()
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(StampedTraceResponse(ok: true))

        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            requestInterceptors: [HeaderStampingInterceptor(label: "session-only", recorder: recorder)],
            responseInterceptors: [ResponseStampingInterceptor(label: "session-only", recorder: recorder)]
        )
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        let request = StampedTraceRequest(
            endpointRequestInterceptors: [],
            endpointResponseInterceptors: []
        )
        _ = try await client.request(request)

        #expect(recorder.snapshot == ["req:session-only", "res:session-only"])
    }

    @Test("Endpoint-only interceptors keep the previous behaviour")
    func endpointOnlyChain() async throws {
        let recorder = TraceRecorder()
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(StampedTraceResponse(ok: true))

        let configuration = makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1")
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        let request = StampedTraceRequest(
            endpointRequestInterceptors: [HeaderStampingInterceptor(label: "endpoint-only", recorder: recorder)],
            endpointResponseInterceptors: [ResponseStampingInterceptor(label: "endpoint-only", recorder: recorder)]
        )
        _ = try await client.request(request)

        #expect(recorder.snapshot == ["req:endpoint-only", "res:endpoint-only"])
    }

    @Test("Response interceptor status rewrite controls success validation")
    func responseInterceptorStatusRewriteControlsSuccessValidation() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 500, data: Data("server failed".utf8))

        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            responseInterceptors: [
                ResponseRewritingInterceptor(
                    statusCode: 200,
                    response: StampedTraceResponse(ok: true)
                )
            ]
        )
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        let response = try await client.request(
            StampedTraceRequest(
                endpointRequestInterceptors: [],
                endpointResponseInterceptors: []
            )
        )

        #expect(response == StampedTraceResponse(ok: true))
    }

    @Test("Response interceptor body rewrite feeds the final decoder")
    func responseInterceptorBodyRewriteFeedsDecoder() async throws {
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(StampedTraceResponse(ok: false))

        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            responseInterceptors: [
                ResponseRewritingInterceptor(
                    statusCode: 200,
                    response: StampedTraceResponse(ok: true)
                )
            ]
        )
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        let response = try await client.request(
            StampedTraceRequest(
                endpointRequestInterceptors: [],
                endpointResponseInterceptors: []
            )
        )

        #expect(response == StampedTraceResponse(ok: true))
    }

    @Test("AdvancedBuilder exposes interceptor slots for tuning")
    func advancedBuilderExposesInterceptorSlots() {
        let recorder = TraceRecorder()
        let configuration = NetworkConfiguration.advanced(
            baseURL: URL(string: "https://api.example.com/v1")!
        ) { builder in
            builder.requestInterceptors = [HeaderStampingInterceptor(label: "adv-req", recorder: recorder)]
            builder.responseInterceptors = [ResponseStampingInterceptor(label: "adv-res", recorder: recorder)]
        }
        #expect(configuration.requestInterceptors.count == 1)
        #expect(configuration.responseInterceptors.count == 1)
    }
}
