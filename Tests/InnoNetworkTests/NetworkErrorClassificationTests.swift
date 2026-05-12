import Foundation
import Testing

@testable import InnoNetwork

@Suite("NetworkError classification helpers")
struct NetworkErrorClassificationTests {
    @Test("category maps each public error case")
    func categoryMapsEachPublicErrorCase() {
        #expect(NetworkError.configuration(reason: .invalidRequest("bad")).category == .configuration)
        #expect(NetworkError.statusCode(response(statusCode: 500)).category == .statusCode)
        #expect(decodingError.category == .decoding)
        #expect(underlyingError.category == .transport)
        #expect(reachabilityError.category == .reachability)
        #expect(NetworkError.trustEvaluationFailed(.missingServerTrust).category == .trust)
        #expect(NetworkError.cancelled.category == .cancellation)
        #expect(NetworkError.timeout(reason: .requestTimeout).category == .timeout)
    }

    @Test("retry hint mirrors built-in transient classes")
    func retryHintMirrorsBuiltInTransientClasses() {
        #expect(NetworkError.statusCode(response(statusCode: 408)).isRetriableHint)
        #expect(NetworkError.statusCode(response(statusCode: 429)).isRetriableHint)
        #expect(NetworkError.statusCode(response(statusCode: 503)).isRetriableHint)
        #expect(NetworkError.statusCode(response(statusCode: 404)).isRetriableHint == false)
        #expect(underlyingError.isRetriableHint)
        #expect(reachabilityError.isRetriableHint)
        #expect(NetworkError.timeout(reason: .connectionTimeout).isRetriableHint)
        #expect(NetworkError.cancelled.isRetriableHint == false)
        #expect(decodingError.isRetriableHint == false)
        #expect(NetworkError.trustEvaluationFailed(.missingServerTrust).isRetriableHint == false)
    }

    @Test("user visible hint suppresses programmer errors and cancellation")
    func userVisibleHintSuppressesProgrammerErrorsAndCancellation() {
        #expect(NetworkError.configuration(reason: .invalidBaseURL("bad")).isUserVisible == false)
        #expect(NetworkError.configuration(reason: .invalidRequest("bad")).isUserVisible == false)
        #expect(NetworkError.configuration(reason: .offline("offline")).isUserVisible)
        #expect(NetworkError.cancelled.isUserVisible == false)
        #expect(NetworkError.statusCode(response(statusCode: 500)).isUserVisible)
        #expect(NetworkError.timeout(reason: .requestTimeout).isUserVisible)
    }

    private var decodingError: NetworkError {
        NetworkError.decoding(
            stage: .responseBody,
            underlying: SendableUnderlyingError(domain: "test", code: 1, message: "decode"),
            response: response(statusCode: 200)
        )
    }

    private var underlyingError: NetworkError {
        NetworkError.underlying(
            SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.Code.networkConnectionLost.rawValue,
                message: "lost"
            ),
            nil
        )
    }

    private var reachabilityError: NetworkError {
        NetworkError.reachability(
            .notConnectedToInternet,
            SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.Code.notConnectedToInternet.rawValue,
                message: "offline"
            ),
            nil
        )
    }

    private func response(statusCode: Int) -> Response {
        let url = URL(string: "https://api.example.com/error")!
        let request = URLRequest(url: url)
        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return Response(statusCode: statusCode, data: Data(), request: request, response: httpResponse)
    }
}
