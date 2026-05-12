import Foundation
import Testing

@testable import InnoNetwork

@Suite("NetworkError wire matrix")
struct NetworkErrorWireMatrixTests {
    @Test("statusCode case is emitted through transport response validation")
    func statusCodeCaseFromTransport() async throws {
        let error = try await captureError(
            session: MatrixSession { request in
                (
                    Data("{}".utf8),
                    httpResponse(url: request.url!, statusCode: 500)
                )
            }
        )

        guard case .statusCode(let response) = error else {
            Issue.record("Expected .statusCode, got \(error)")
            return
        }
        #expect(response.statusCode == 500)
        assertNSError(error, code: .statusCode)
    }

    @Test("decoding case is emitted through response decoder")
    func decodingCaseFromDecoder() async throws {
        let error = try await captureError(
            session: MatrixSession { request in
                (
                    Data("{".utf8),
                    httpResponse(url: request.url!, statusCode: 200)
                )
            }
        )

        guard case .decoding(let stage, _, _) = error else {
            Issue.record("Expected .decoding, got \(error)")
            return
        }
        #expect(stage == .responseBody)
        assertNSError(error, code: .decoding)
    }

    @Test("underlying case is emitted through transport failure")
    func underlyingCaseFromTransportFailure() async throws {
        let error = try await captureError(
            session: MatrixSession { _ in
                throw NSError(domain: "matrix.transport", code: 7)
            }
        )

        guard case .underlying(let underlying, nil) = error else {
            Issue.record("Expected .underlying, got \(error)")
            return
        }
        #expect(underlying.domain == "matrix.transport")
        assertNSError(error, code: .underlying)
    }

    @Test("reachability case is emitted through classified URLError")
    func reachabilityCaseFromURLError() async throws {
        let error = try await captureError(
            session: MatrixSession { _ in
                throw URLError(.notConnectedToInternet)
            }
        )

        guard case .reachability(.notConnectedToInternet, _, nil) = error else {
            Issue.record("Expected .reachability(.notConnectedToInternet), got \(error)")
            return
        }
        assertNSError(error, code: .reachability)
    }

    @Test("trustEvaluationFailed case is emitted through trust transport wrapper")
    func trustEvaluationFailedCaseFromTrustWrapper() async throws {
        let error = try await captureError(
            session: MatrixSession { _ in
                throw TrustEvaluationError.failed(.missingServerTrust, URLError(.secureConnectionFailed))
            }
        )

        guard case .trustEvaluationFailed(.missingServerTrust) = error else {
            Issue.record("Expected .trustEvaluationFailed(.missingServerTrust), got \(error)")
            return
        }
        assertNSError(error, code: .trustEvaluationFailed)
    }

    @Test("cancelled case is emitted through classified URLError")
    func cancelledCaseFromURLError() async throws {
        let error = try await captureError(
            session: MatrixSession { _ in
                throw URLError(.cancelled)
            }
        )

        guard case .cancelled = error else {
            Issue.record("Expected .cancelled, got \(error)")
            return
        }
        assertNSError(error, code: .cancelled)
    }

    @Test("timeout case is emitted through classified URLError")
    func timeoutCaseFromURLError() async throws {
        let error = try await captureError(
            session: MatrixSession { _ in
                throw URLError(.timedOut)
            }
        )

        guard case .timeout(.requestTimeout, _) = error else {
            Issue.record("Expected .timeout(.requestTimeout), got \(error)")
            return
        }
        assertNSError(error, code: .timeout)
    }

    @Test("configuration invalid base URL case is emitted before transport")
    func configurationInvalidBaseURLFromRequestBuild() async throws {
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "http://example.com")!,
                networkMonitor: nil
            ),
            session: MatrixSession { _ in
                Issue.record("Transport must not be called for invalid base URL")
                throw URLError(.badURL)
            }
        )

        do {
            _ = try await client.request(MatrixEndpoint())
            Issue.record("Expected invalid base URL configuration error")
        } catch let error as NetworkError {
            guard case .configuration(reason: .invalidBaseURL) = error else {
                Issue.record("Expected .configuration(.invalidBaseURL), got \(error)")
                return
            }
            assertNSError(error, code: .configurationInvalidBaseURL)
        }
    }

    @Test("configuration invalid request case is emitted before transport")
    func configurationInvalidRequestFromAuthScope() async throws {
        let client = DefaultNetworkClient(
            configuration: matrixConfiguration(),
            session: MatrixSession { _ in
                Issue.record("Transport must not be called for invalid auth request")
                throw URLError(.badURL)
            }
        )

        do {
            _ = try await client.request(MatrixAuthRequiredEndpoint())
            Issue.record("Expected invalid request configuration error")
        } catch let error as NetworkError {
            guard case .configuration(reason: .invalidRequest) = error else {
                Issue.record("Expected .configuration(.invalidRequest), got \(error)")
                return
            }
            assertNSError(error, code: .configurationInvalidRequest)
        }
    }

    @Test("configuration offline case is emitted through execution policy")
    func configurationOfflineFromExecutionPolicy() async throws {
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "https://example.com")!,
                networkMonitor: nil,
                customExecutionPolicies: [OfflineMatrixPolicy()]
            ),
            session: MatrixSession { _ in
                Issue.record("Transport must not be called while offline policy rejects")
                throw URLError(.badURL)
            }
        )

        do {
            _ = try await client.request(MatrixEndpoint())
            Issue.record("Expected offline configuration error")
        } catch let error as NetworkError {
            guard case .configuration(reason: .offline) = error else {
                Issue.record("Expected .configuration(.offline), got \(error)")
                return
            }
            assertNSError(error, code: .configurationOffline)
        }
    }

    private func captureError(session: URLSessionProtocol) async throws -> NetworkError {
        let client = DefaultNetworkClient(configuration: matrixConfiguration(), session: session)
        do {
            _ = try await client.request(MatrixEndpoint())
            throw NSError(domain: "NetworkErrorWireMatrixTests", code: 1)
        } catch let error as NetworkError {
            return error
        }
    }

    private func matrixConfiguration() -> NetworkConfiguration {
        NetworkConfiguration(
            baseURL: URL(string: "https://example.com")!,
            networkMonitor: nil
        )
    }

    private func assertNSError(_ error: NetworkError, code: NetworkErrorCode) {
        let bridged = error as NSError
        #expect(bridged.domain == NetworkError.errorDomain)
        #expect(bridged.code == code.rawValue)
    }
}

private struct MatrixPayload: Codable, Sendable, Equatable {
    let id: Int
}

private struct MatrixEndpoint: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = MatrixPayload

    var method: HTTPMethod { .get }
    var path: String { "/matrix" }
}

private struct MatrixAuthRequiredEndpoint: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = MatrixPayload
    typealias Auth = AuthRequiredScope

    var method: HTTPMethod { .get }
    var path: String { "/matrix" }
}

private struct OfflineMatrixPolicy: RequestExecutionPolicy {
    func execute(
        input: RequestExecutionInput,
        context: RequestExecutionContext,
        next: RequestExecutionNext
    ) async throws -> Response {
        _ = (input, context, next)
        throw NetworkError.configuration(reason: .offline("matrix offline"))
    }
}

private final class MatrixSession: URLSessionProtocol, Sendable {
    private let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}

private func httpResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
}
