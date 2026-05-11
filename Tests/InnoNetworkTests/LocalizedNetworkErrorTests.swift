import Foundation
import Testing

@testable import InnoNetwork

/// Verifies that `NetworkError.errorDescription` is wired through the
/// `Sources/InnoNetwork/Resources/<lang>.lproj/Localizable.strings`
/// catalogue that ships with the package (`en` and `ko` as of 4.x).
///
/// The runtime locale of XCTest/Swift Testing is host-dependent, so the
/// black-box assertions below check only that the description is
/// non-empty and that every payload value reaches the rendered string.
/// The catalogue contents themselves are exercised through the
/// ``_localizedNetworkErrorString(forKey:localization:)`` package probe.
@Suite("Localized NetworkError descriptions")
struct LocalizedNetworkErrorTests {

    // MARK: - Black-box: every case yields a useful description

    @Test("every case produces a non-empty errorDescription")
    func everyCaseProducesNonEmptyDescription() throws {
        let response = try makeResponse(statusCode: 500)
        let cases: [NetworkError] = [
            .configuration(reason: .invalidBaseURL("ftp://example.com")),
            .configuration(reason: .invalidRequest("missing path")),
            .configuration(reason: .offline("device path is .unsatisfied")),
            .decoding(
                stage: .responseBody,
                underlying: SendableUnderlyingError(
                    domain: "test",
                    code: 1,
                    message: "bad json"
                ),
                response: response
            ),
            .statusCode(response),
            .underlying(
                SendableUnderlyingError(domain: "test", code: 2, message: "boom"),
                nil
            ),
            .trustEvaluationFailed(.missingServerTrust),
            .trustEvaluationFailed(.unsupportedAuthenticationMethod("custom")),
            .trustEvaluationFailed(.systemTrustEvaluationFailed(reason: nil)),
            .trustEvaluationFailed(.systemTrustEvaluationFailed(reason: "expired")),
            .trustEvaluationFailed(.hostNotPinned("api.example.com")),
            .trustEvaluationFailed(.publicKeyExtractionFailed),
            .trustEvaluationFailed(.pinMismatch(host: "api.example.com")),
            .trustEvaluationFailed(.custom("custom trust message")),
            .cancelled,
            .timeout(reason: .requestTimeout),
            .timeout(reason: .resourceTimeout),
            .timeout(reason: .connectionTimeout),
            .reachability(
                .notConnectedToInternet,
                SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorNotConnectedToInternet,
                    message: "offline"
                ),
                nil
            ),
            .reachability(
                .dnsLookupFailed,
                SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorDNSLookupFailed,
                    message: "dns failed"
                ),
                nil
            ),
            .reachability(
                .cannotFindHost,
                SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorCannotFindHost,
                    message: "no host"
                ),
                nil
            ),
            .reachability(
                .networkConnectionLost,
                SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorNetworkConnectionLost,
                    message: "connection lost"
                ),
                nil
            ),
        ]

        for error in cases {
            let description = error.errorDescription
            #expect(description != nil, "errorDescription is nil for \(error)")
            #expect(description?.isEmpty == false, "errorDescription is empty for \(error)")
        }
    }

    @Test("payload values are interpolated into the rendered description")
    func payloadValuesAreInterpolated() {
        #expect(
            NetworkError.configuration(reason: .invalidBaseURL("ftp://example.com"))
                .errorDescription?.contains("ftp://example.com") == true
        )
        #expect(
            NetworkError.configuration(reason: .invalidRequest("missing path"))
                .errorDescription?.contains("missing path") == true
        )
        #expect(
            NetworkError.trustEvaluationFailed(.hostNotPinned("api.example.com"))
                .errorDescription?.contains("api.example.com") == true
        )
        #expect(
            NetworkError.trustEvaluationFailed(.pinMismatch(host: "api.example.com"))
                .errorDescription?.contains("api.example.com") == true
        )
    }

    @Test(".underlying surfaces the underlying error message verbatim")
    func underlyingSurfacesMessage() {
        let error = NetworkError.underlying(
            SendableUnderlyingError(
                domain: "ExampleDomain",
                code: 7,
                message: "specific underlying detail"
            ),
            nil
        )
        #expect(error.errorDescription == "specific underlying detail")
    }

    // MARK: - Catalogue probe

    /// Every documented key must resolve in the English catalogue so a
    /// missing translation never silently falls back to the key itself.
    private static let translatedKeys: [String] = [
        "NetworkError.invalidBaseURL",
        "NetworkError.invalidRequestConfiguration",
        "NetworkError.offline",
        "NetworkError.decoding",
        "NetworkError.statusCode",
        "NetworkError.cancelled",
        "NetworkError.timeout.request",
        "NetworkError.timeout.resource",
        "NetworkError.timeout.connection",
        "NetworkError.reachability.notConnectedToInternet",
        "NetworkError.reachability.dnsLookupFailed",
        "NetworkError.reachability.cannotFindHost",
        "NetworkError.reachability.networkConnectionLost",
        "NetworkError.trust.unsupportedAuthenticationMethod",
        "NetworkError.trust.missingServerTrust",
        "NetworkError.trust.systemTrustEvaluationFailedWithReason",
        "NetworkError.trust.systemTrustEvaluationFailed",
        "NetworkError.trust.hostNotPinned",
        "NetworkError.trust.publicKeyExtractionFailed",
        "NetworkError.trust.pinMismatch",
    ]

    @Test("English catalogue resolves every documented key")
    func englishCatalogueHasEveryKey() {
        for key in Self.translatedKeys {
            let value = _localizedNetworkErrorString(forKey: key, localization: "en")
            #expect(value != nil, "missing English string for \(key)")
            #expect(value?.isEmpty == false, "empty English string for \(key)")
        }
    }

    @Test("Korean catalogue resolves every documented key")
    func koreanCatalogueHasEveryKey() {
        for key in Self.translatedKeys {
            let value = _localizedNetworkErrorString(forKey: key, localization: "ko")
            #expect(value != nil, "missing Korean string for \(key)")
            #expect(value?.isEmpty == false, "empty Korean string for \(key)")
        }
    }

    // MARK: - Helpers

    private func makeResponse(statusCode: Int) throws -> Response {
        struct LocalizedNetworkErrorTestsError: Error {
            let message: String
        }
        guard
            let url = URL(string: "https://example.com/test"),
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        else {
            throw LocalizedNetworkErrorTestsError(
                message: "failed to construct HTTPURLResponse"
            )
        }
        return Response(statusCode: statusCode, data: Data(), response: httpResponse)
    }

    @Test("English strings do not contain Hangul (catalogue swap guard)")
    func englishStringsAreNotHangul() {
        let sampledKeys = [
            "NetworkError.statusCode",
            "NetworkError.cancelled",
            "NetworkError.timeout.request",
        ]
        for key in sampledKeys {
            let value = _localizedNetworkErrorString(forKey: key, localization: "en") ?? ""
            let hasHangul = value.unicodeScalars.contains { scalar in
                (0xAC00...0xD7A3).contains(scalar.value)
            }
            #expect(!hasHangul, "English string for \(key) contains Hangul: \(value)")
        }
    }

    @Test("Korean strings contain Hangul (catalogue swap guard)")
    func koreanStringsContainHangul() {
        let sampledKeys = [
            "NetworkError.statusCode",
            "NetworkError.cancelled",
            "NetworkError.timeout.request",
            "NetworkError.reachability.notConnectedToInternet",
        ]
        for key in sampledKeys {
            let value = _localizedNetworkErrorString(forKey: key, localization: "ko") ?? ""
            let hasHangul = value.unicodeScalars.contains { scalar in
                (0xAC00...0xD7A3).contains(scalar.value)
            }
            #expect(hasHangul, "Korean string for \(key) has no Hangul: \(value)")
        }
    }
}
