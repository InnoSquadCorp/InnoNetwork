import Foundation
import Testing

@testable import InnoNetwork

@Suite("NetworkErrorCode SSOT contract")
struct NetworkErrorCodeTests {
    // CONTRACT LOCK: do not renumber existing cases without a major bump.
    @Test("raw values are frozen")
    func rawValuesAreFrozen() {
        #expect(NetworkErrorCode.configurationInvalidBaseURL.rawValue == 1001)
        #expect(NetworkErrorCode.configurationInvalidRequest.rawValue == 1002)
        #expect(NetworkErrorCode.configurationOffline.rawValue == 1003)
        #expect(NetworkErrorCode.decoding.rawValue == 2002)
        #expect(NetworkErrorCode.statusCode.rawValue == 3001)
        #expect(NetworkErrorCode.nonHTTPResponse.rawValue == 3002)
        #expect(NetworkErrorCode.underlying.rawValue == 4001)
        #expect(NetworkErrorCode.reachability.rawValue == 4002)
        #expect(NetworkErrorCode.responseBodyLimitExceeded.rawValue == 4003)
        #expect(NetworkErrorCode.trustEvaluationFailed.rawValue == 5001)
    }

    @Test("2001 is intentionally unused")
    func gapAt2001() {
        #expect(NetworkErrorCode(rawValue: 2001) == nil)
    }

    @Test("all known codes are unique")
    func codesAreUnique() {
        // Enumerated explicitly (not via `.allCases`) so the public surface
        // does not need `CaseIterable` — adding it would lock in
        // iteration-order/count as part of the SemVer contract.
        let raws: [Int] = [
            NetworkErrorCode.configurationInvalidBaseURL.rawValue,
            NetworkErrorCode.configurationInvalidRequest.rawValue,
            NetworkErrorCode.configurationOffline.rawValue,
            NetworkErrorCode.decoding.rawValue,
            NetworkErrorCode.statusCode.rawValue,
            NetworkErrorCode.nonHTTPResponse.rawValue,
            NetworkErrorCode.underlying.rawValue,
            NetworkErrorCode.reachability.rawValue,
            NetworkErrorCode.responseBodyLimitExceeded.rawValue,
            NetworkErrorCode.trustEvaluationFailed.rawValue,
        ]
        #expect(Set(raws).count == raws.count)
    }

    @Test("NetworkError.errorCode routes through SSOT")
    func errorCodeRoutesThroughSSOT() {
        let underlying = SendableUnderlyingError(domain: "test", code: 0, message: "test")
        #expect(
            NetworkError.configuration(reason: .invalidBaseURL("x")).errorCode
                == NetworkErrorCode.configurationInvalidBaseURL.rawValue)
        #expect(
            NetworkError.configuration(reason: .invalidRequest("x")).errorCode
                == NetworkErrorCode.configurationInvalidRequest.rawValue)
        #expect(
            NetworkError.configuration(reason: .offline("x")).errorCode
                == NetworkErrorCode.configurationOffline.rawValue)
        #expect(
            NetworkError.underlying(underlying, nil).errorCode
                == NetworkErrorCode.underlying.rawValue)
        #expect(NetworkError.cancelled.errorCode == NSURLErrorCancelled)
    }
}
