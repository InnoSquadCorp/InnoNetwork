import Foundation
import Testing

@testable import InnoNetwork

/// Contract tests for the 7.0 error model: local policy rejections and
/// authentication failures have their own cases, codes and classification.
@Suite("NetworkError 7.0 model")
struct NetworkErrorModelTests {
    private static let openCircuit = CircuitBreakerOpenError(host: "api.example.com:443", retryAfter: 12.5)

    private static let rejections: [(NetworkPolicyRejection, NetworkErrorCode)] = [
        (.responseBodyLimitExceeded(limitBytes: 1_024, observedBytes: 4_096), .responseBodyLimitExceeded),
        (.circuitOpen(openCircuit), .circuitOpen),
        (.rateLimitQueueFull, .rateLimitQueueRejected),
        (.rateLimitScopeLimitReached, .rateLimitScopeRejected),
        (.admissionQueueFull, .requestAdmissionRejected),
        (.admissionWaitExpired, .requestAdmissionWaitExpired),
        (.nonHTTPResponse, .nonHTTPResponse),
    ]

    private static let refreshCause = SendableUnderlyingError(
        domain: "app.auth",
        code: 7,
        message: "refresh token revoked"
    )

    @Test("Every policy rejection has a stable code, the policy category and no retry hint")
    func policyRejectionClassification() {
        for (rejection, code) in Self.rejections {
            let error = NetworkError.policyRejected(rejection)
            #expect(error.errorCode == code.rawValue, "\(rejection)")
            #expect(rejection.code == code, "\(rejection)")
            #expect(error.category == .policy, "\(rejection)")
            #expect(error.isRetriableHint == false, "\(rejection)")
            #expect(error.isUserVisible, "\(rejection)")
            #expect(error.response == nil, "\(rejection)")
            #expect(error.errorDescription?.isEmpty == false, "\(rejection)")
        }
    }

    @Test("Authentication failures have stable codes, their own category and no retry hint")
    func authenticationClassification() {
        let refresh = NetworkError.authentication(.refreshFailed(Self.refreshCause))
        #expect(refresh.errorCode == NetworkErrorCode.authenticationRefreshFailed.rawValue)
        #expect(refresh.category == .authentication)
        #expect(refresh.isRetriableHint == false)
        #expect(refresh.errorDescription?.contains("refresh token revoked") == true)

        let credential = NetworkError.authentication(.credential(.credentialExpired))
        #expect(credential.errorCode == NetworkErrorCode.requestCredentialFailed.rawValue)
        #expect(credential.category == .authentication)
        #expect(credential.isRetriableHint == false)
        #expect(credential.errorDescription?.isEmpty == false)
    }

    @Test("Body-limit description states the observed size and the limit")
    func bodyLimitDescription() {
        let description = NetworkError.policyRejected(
            .responseBodyLimitExceeded(limitBytes: 1_024, observedBytes: 4_096)
        ).errorDescription

        #expect(description?.contains("4096") == true)
        #expect(description?.contains("1024") == true)
    }

    @Test("NSError bridging exposes the specific code and the refresh cause")
    func nsErrorBridging() {
        let bodyLimit =
            NetworkError.policyRejected(
                .responseBodyLimitExceeded(limitBytes: 1, observedBytes: 2)
            ) as NSError
        #expect(bodyLimit.domain == NetworkError.errorDomain)
        #expect(bodyLimit.code == NetworkErrorCode.responseBodyLimitExceeded.rawValue)
        #expect(
            bodyLimit.userInfo[NetworkError.errorCodeUserInfoKey] as? Int
                == NetworkErrorCode.responseBodyLimitExceeded.rawValue
        )

        let refresh = NetworkError.authentication(.refreshFailed(Self.refreshCause)) as NSError
        #expect(refresh.code == NetworkErrorCode.authenticationRefreshFailed.rawValue)
        let cause = refresh.userInfo[NSUnderlyingErrorKey] as? SendableUnderlyingError
        #expect(cause == Self.refreshCause)
    }

    @Test("Typed sources thrown as plain errors map to their own cases")
    func transportMappingOfTypedSources() {
        let credential = NetworkError.mapTransportError(RequestSecurityFailure.insufficientScope)
        guard case .authentication(.credential(.insufficientScope)) = credential else {
            Issue.record("Expected a credential failure, got \(credential)")
            return
        }

        let open = NetworkError.mapTransportError(Self.openCircuit)
        guard case .policyRejected(.circuitOpen(let payload)) = open else {
            Issue.record("Expected an open-circuit rejection, got \(open)")
            return
        }
        #expect(payload == Self.openCircuit)
    }

    private static func refreshEndpointFailure(statusCode: Int) -> NetworkError {
        let response = HTTPURLResponse(
            url: URL(string: "https://auth.example.com/token")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return .statusCode(Response(statusCode: statusCode, data: Data(), response: response))
    }

    @Test(
        "A transient failure of the refresh request keeps its identity",
        arguments: [408, 429, 500, 502, 503, 504]
    )
    func transientRefreshStatusStaysTransient(statusCode: Int) {
        let surfaced = NetworkError.sessionRefreshFailed(Self.refreshEndpointFailure(statusCode: statusCode))

        guard case .statusCode(let response) = surfaced else {
            Issue.record("A transient refresh status must not become an authentication failure, got \(surfaced)")
            return
        }
        #expect(response.statusCode == statusCode)
        #expect(surfaced.isRetriableHint)
        let summary = surfaced.summary(method: .get, authentication: .required)
        #expect(summary.recovery == .retry)
        #expect(summary.recovery != .reauthenticate)
    }

    @Test(
        "A rejected refresh request is an authentication failure",
        arguments: [400, 401, 403, 404]
    )
    func rejectedRefreshStatusIsAuthenticationFailure(statusCode: Int) {
        let surfaced = NetworkError.sessionRefreshFailed(Self.refreshEndpointFailure(statusCode: statusCode))

        guard case .authentication(.refreshFailed) = surfaced else {
            Issue.record("A rejected refresh must become an authentication failure, got \(surfaced)")
            return
        }
        #expect(surfaced.summary(method: .get, authentication: .required).recovery == .reauthenticate)
    }

    @Test("A failed refresh keeps failures that say nothing about the session")
    func refreshFailureKeepsSessionNeutralFailures() {
        let badServerResponse = NetworkError.sessionRefreshFailed(URLError(.badServerResponse))
        guard case .underlying = badServerResponse else {
            Issue.record("An unclassified transport error must stay transient, got \(badServerResponse)")
            return
        }
        #expect(badServerResponse.isRetriableHint)

        let open = NetworkError.sessionRefreshFailed(
            NetworkError.policyRejected(.circuitOpen(Self.openCircuit))
        )
        guard case .policyRejected(.circuitOpen) = open else {
            Issue.record("An open circuit on the token host is a local rejection, got \(open)")
            return
        }

        let offline = NetworkError.sessionRefreshFailed(
            NetworkError.configuration(reason: .offline("device path is .unsatisfied"))
        )
        guard case .configuration(reason: .offline) = offline else {
            Issue.record("An offline refresh must stay a connectivity failure, got \(offline)")
            return
        }
    }

    @Test("A failed refresh keeps transient causes transient and wraps everything else")
    func sessionRefreshFailureMapping() {
        struct AppRejected: Error {}

        guard case .authentication(.refreshFailed) = NetworkError.sessionRefreshFailed(AppRejected()) else {
            Issue.record("An application error must become an authentication failure")
            return
        }
        guard
            case .authentication(.refreshFailed) = NetworkError.sessionRefreshFailed(
                DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad token response"))
            )
        else {
            Issue.record("An undecodable token response must become an authentication failure")
            return
        }
        guard
            case .reachability(.notConnectedToInternet, _, _) = NetworkError.sessionRefreshFailed(
                URLError(.notConnectedToInternet)
            )
        else {
            Issue.record("A connectivity failure must stay a reachability failure")
            return
        }
        guard case .timeout = NetworkError.sessionRefreshFailed(URLError(.timedOut)) else {
            Issue.record("A timeout must stay a timeout")
            return
        }
        guard case .cancelled = NetworkError.sessionRefreshFailed(CancellationError()) else {
            Issue.record("Cancellation must stay cancellation")
            return
        }
    }

    @Test("TimeoutReason stays Hashable with the payload-carrying deadline case")
    func timeoutReasonRemainsHashable() {
        let reasons: Set<TimeoutReason> = [
            .requestTimeout,
            .resourceTimeout,
            .connectionTimeout,
            .operationDeadline(.transport),
            .operationDeadline(.retryDelay),
            .operationDeadline(.transport),
        ]
        #expect(reasons.count == 5)
    }

    @Test("Unclassified transport errors remain transient")
    func unclassifiedTransportErrorsStayTransient() {
        let error = NetworkError.underlying(
            SendableUnderlyingError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, message: "bad"),
            nil
        )
        #expect(error.category == .transport)
        #expect(error.isRetriableHint)
    }
}
