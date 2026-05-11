import Foundation
import Testing

@testable import InnoNetwork

@Suite("NetworkError.reachability mapping & accessors")
struct NetworkErrorReachabilityTests {

    // MARK: - mapTransportError → .reachability classification

    @Test("URLError.notConnectedToInternet → .reachability(.notConnectedToInternet)")
    func mapsNotConnected() {
        let mapped = NetworkError.mapTransportError(URLError(.notConnectedToInternet))
        guard case .reachability(.notConnectedToInternet, let underlying, nil) = mapped else {
            Issue.record("Expected .reachability(.notConnectedToInternet), got \(mapped)")
            return
        }
        #expect(underlying.domain == NSURLErrorDomain)
        #expect(underlying.code == URLError.Code.notConnectedToInternet.rawValue)
    }

    @Test("URLError.dnsLookupFailed → .reachability(.dnsLookupFailed)")
    func mapsDNSLookupFailed() {
        let mapped = NetworkError.mapTransportError(URLError(.dnsLookupFailed))
        guard case .reachability(.dnsLookupFailed, let underlying, nil) = mapped else {
            Issue.record("Expected .reachability(.dnsLookupFailed), got \(mapped)")
            return
        }
        #expect(underlying.code == URLError.Code.dnsLookupFailed.rawValue)
    }

    @Test("URLError.cannotFindHost → .reachability(.cannotFindHost)")
    func mapsCannotFindHost() {
        let mapped = NetworkError.mapTransportError(URLError(.cannotFindHost))
        guard case .reachability(.cannotFindHost, let underlying, nil) = mapped else {
            Issue.record("Expected .reachability(.cannotFindHost), got \(mapped)")
            return
        }
        #expect(underlying.code == URLError.Code.cannotFindHost.rawValue)
    }

    @Test("URLError.networkConnectionLost → .reachability(.networkConnectionLost)")
    func mapsNetworkConnectionLost() {
        let mapped = NetworkError.mapTransportError(URLError(.networkConnectionLost))
        guard case .reachability(.networkConnectionLost, let underlying, nil) = mapped else {
            Issue.record("Expected .reachability(.networkConnectionLost), got \(mapped)")
            return
        }
        #expect(underlying.code == URLError.Code.networkConnectionLost.rawValue)
    }

    // MARK: - NSError bridge / errorCode

    // CONTRACT LOCK: .reachability bridges to NetworkErrorCode.reachability (4002).
    @Test(".reachability bridges through NetworkErrorCode.reachability (4002)")
    func errorCodeRoutesThroughSSOT() {
        let mapped = NetworkError.mapTransportError(URLError(.notConnectedToInternet))
        #expect(mapped.errorCode == NetworkErrorCode.reachability.rawValue)
        let bridged = mapped as NSError
        #expect(bridged.domain == NetworkError.errorDomain)
        #expect(bridged.code == 4002)
    }

    // MARK: - Localized descriptions

    @Test("Localized description differentiates between reachability reasons")
    func localizedDescriptionDifferentiates() {
        let underlying = SendableUnderlyingError(URLError(.notConnectedToInternet))
        let descriptions: [String?] = [
            NetworkError.reachability(.notConnectedToInternet, underlying, nil).errorDescription,
            NetworkError.reachability(.dnsLookupFailed, underlying, nil).errorDescription,
            NetworkError.reachability(.cannotFindHost, underlying, nil).errorDescription,
            NetworkError.reachability(.networkConnectionLost, underlying, nil).errorDescription,
        ]
        let nonNil = descriptions.compactMap { $0 }
        #expect(nonNil.count == 4)
        #expect(Set(nonNil).count == 4, "Each reason must produce a distinct description: \(nonNil)")
    }

    // MARK: - Redaction preserves reason + underlying

    @Test("redactingFailurePayload preserves reason and underlying, zeroes Response.data")
    func redactionPreservesReason() {
        let payload = Data("secret".utf8)
        let url = URL(string: "https://api.example.com/v1/secrets")!
        let response = Response(
            statusCode: 200,
            data: payload,
            request: URLRequest(url: url),
            response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
        let underlying = SendableUnderlyingError(URLError(.networkConnectionLost))
        let original = NetworkError.reachability(.networkConnectionLost, underlying, response)
        guard case .reachability(let reason, let preservedUnderlying, let redactedResponse) =
            original.redactingFailurePayload()
        else {
            Issue.record("Expected redacted .reachability, got something else")
            return
        }
        #expect(reason == .networkConnectionLost)
        #expect(preservedUnderlying.code == URLError.Code.networkConnectionLost.rawValue)
        #expect(redactedResponse?.data.isEmpty == true)
        #expect(redactedResponse?.statusCode == 200)
    }

    @Test("redactingFailurePayload with nil response returns self unchanged")
    func redactionWithNilResponse() {
        let underlying = SendableUnderlyingError(URLError(.dnsLookupFailed))
        let original = NetworkError.reachability(.dnsLookupFailed, underlying, nil)
        guard case .reachability(.dnsLookupFailed, _, nil) = original.redactingFailurePayload() else {
            Issue.record("Expected pass-through, got something else")
            return
        }
    }

    // MARK: - response/underlyingError accessors

    @Test("response accessor returns the carried Response, underlyingError returns the URLError envelope")
    func accessorsExposeAssociatedValues() {
        let url = URL(string: "https://api.example.com/v1/x")!
        let response = Response(
            statusCode: 503,
            data: Data(),
            request: nil,
            response: HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!
        )
        let underlying = SendableUnderlyingError(URLError(.cannotFindHost))
        let error = NetworkError.reachability(.cannotFindHost, underlying, response)
        #expect(error.response?.statusCode == 503)
        #expect(error.underlyingError?.code == URLError.Code.cannotFindHost.rawValue)
    }
}
