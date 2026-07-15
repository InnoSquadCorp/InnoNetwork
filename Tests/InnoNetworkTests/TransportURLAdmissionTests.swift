import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork

private struct URLAdmissionResponse: Codable, Equatable, Sendable {
    let value: String
}


private struct URLAdmissionRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = URLAdmissionResponse

    var sessionAuthentication: SessionAuthentication
    var method: HTTPMethod { .get }
    var path: String { "/admission" }
}


private struct URLAdmissionStream: StreamingAPIDefinition {
    typealias Output = String

    var sessionAuthentication: SessionAuthentication
    let interceptors: [RequestInterceptor]

    var method: HTTPMethod { .get }
    var path: String { "/events" }
    var requestInterceptors: [RequestInterceptor] { interceptors }

    func decode(line: String) throws -> String? {
        line.isEmpty ? nil : line
    }
}


private struct ReplacingURLInterceptor: RequestInterceptor {
    let target: URL

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.url = target
        return request
    }
}


private final class CountingBytesURLSession: URLSessionProtocol, Sendable {
    private let callCountLock = OSAllocatedUnfairLock<Int>(initialState: 0)

    var callCount: Int {
        callCountLock.withLock { $0 }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        _ = request
        callCountLock.withLock { $0 += 1 }
        throw URLError(.badServerResponse)
    }

    func bytes(for request: URLRequest, context: NetworkRequestContext) async throws -> (
        URLSession.AsyncBytes, URLResponse
    ) {
        _ = (request, context)
        callCountLock.withLock { $0 += 1 }
        throw URLError(.badServerResponse)
    }
}


@Suite("Final transport URL admission")
struct TransportURLAdmissionTests {
    @Test(
        "Interceptor-replaced unsafe URLs fail before transport",
        arguments: [
            "file:///tmp/innonetwork-admission",
            "https://user:password@api.example.com/admission",
            "https://api.example.com/safe/%2e%2e/private",
        ]
    )
    func interceptorReplacementFailsClosed(target: String) async throws {
        let targetURL = try #require(URL(string: target))
        let session = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "https://api.example.com")!,
                requestInterceptors: [ReplacingURLInterceptor(target: targetURL)]
            ),
            session: session
        )

        await expectURLAdmissionFailure {
            _ = try await client.request(
                URLAdmissionRequest(sessionAuthentication: .anonymous)
            )
        }
        #expect(session.capturedRequestsInOrder.isEmpty)
    }

    @Test("Current-token applicator cannot replace the initial URL with an unsafe target")
    func currentTokenApplicatorFailsBeforeTransport() async throws {
        let session = MockURLSession()
        let policy = RefreshTokenPolicy(
            currentToken: { "current" },
            refreshToken: { "unused" },
            applyToken: { _, request in
                var request = request
                request.url = URL(string: "file:///tmp/innonetwork-token")!
                return request
            }
        )
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "https://api.example.com")!,
                refreshTokenPolicy: policy
            ),
            session: session
        )

        await expectURLAdmissionFailure {
            _ = try await client.request(
                URLAdmissionRequest(sessionAuthentication: .optional)
            )
        }
        #expect(session.capturedRequestsInOrder.isEmpty)
    }

    @Test("401 refresh replay revalidates a token-applicator replacement")
    func refreshedTokenApplicatorFailsBeforeReplayTransport() async throws {
        let session = MockURLSession()
        session.setScriptedResponses([
            .http(statusCode: 401),
            .http(
                statusCode: 200,
                data: try JSONEncoder().encode(URLAdmissionResponse(value: "unexpected"))
            ),
        ])
        let policy = RefreshTokenPolicy(
            currentToken: { "expired" },
            refreshToken: { "refreshed" },
            applyToken: { token, request in
                var request = request
                if token == "refreshed" {
                    request.url = URL(string: "file:///tmp/innonetwork-refreshed-token")!
                }
                return request
            }
        )
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "https://api.example.com")!,
                refreshTokenPolicy: policy
            ),
            session: session
        )

        await expectURLAdmissionFailure {
            _ = try await client.request(
                URLAdmissionRequest(sessionAuthentication: .optional)
            )
        }
        #expect(session.capturedRequestsInOrder.count == 1)
    }

    @Test("Explicit insecure-HTTP opt-in survives final request admission")
    func explicitInsecureHTTPOptInReachesTransport() async throws {
        let session = MockURLSession()
        try session.setMockJSON(URLAdmissionResponse(value: "ok"))
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "https://api.example.com")!,
                requestInterceptors: [
                    ReplacingURLInterceptor(target: URL(string: "http://api.example.com/admission")!)
                ],
                allowsInsecureHTTP: true
            ),
            session: session
        )

        let response = try await client.request(
            URLAdmissionRequest(sessionAuthentication: .anonymous)
        )

        #expect(response == URLAdmissionResponse(value: "ok"))
        #expect(session.capturedRequest?.url?.scheme == "http")
    }

    @Test("Streaming interceptor replacement fails before bytes transport")
    func streamingInterceptorReplacementFailsBeforeTransport() async throws {
        let session = CountingBytesURLSession()
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: URL(string: "https://api.example.com")!),
            session: session
        )
        let stream = URLAdmissionStream(
            sessionAuthentication: .anonymous,
            interceptors: [
                ReplacingURLInterceptor(target: URL(string: "file:///tmp/innonetwork-stream")!)
            ]
        )

        await expectURLAdmissionFailure {
            for try await _ in client.stream(stream) {}
        }
        #expect(session.callCount == 0)
    }

    @Test("Streaming token applicator replacement fails before bytes transport")
    func streamingTokenApplicatorFailsBeforeTransport() async throws {
        let session = CountingBytesURLSession()
        let policy = RefreshTokenPolicy(
            currentToken: { "stream-token" },
            refreshToken: { "unused" },
            applyToken: { _, request in
                var request = request
                request.url = URL(string: "https://api.example.com/safe/%252e%252e/private")!
                return request
            }
        )
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "https://api.example.com")!,
                refreshTokenPolicy: policy
            ),
            session: session
        )
        let stream = URLAdmissionStream(
            sessionAuthentication: .optional,
            interceptors: []
        )

        await expectURLAdmissionFailure {
            for try await _ in client.stream(stream) {}
        }
        #expect(session.callCount == 0)
    }
}


private func expectURLAdmissionFailure(
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected final URL admission to fail")
    } catch let error as NetworkError {
        guard case .configuration(let reason) = error else {
            Issue.record("Expected NetworkError.configuration, got \(error)")
            return
        }
        switch reason {
        case .invalidBaseURL, .invalidRequest:
            break
        case .offline:
            Issue.record("Expected URL admission failure, got \(reason)")
            return
        }
    } catch {
        Issue.record("Expected NetworkError.configuration, got \(error)")
    }
}
