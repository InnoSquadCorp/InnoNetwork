import Foundation
import Testing

@testable import InnoNetwork

/// Verifies that `NetworkError.errorDescription` is wired through the
/// `Sources/InnoNetwork/Resources/<lang>.lproj/Localizable.strings`
/// catalogues that ship with the package (currently `en` and `ko`).
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
            .invalidBaseURL("ftp://example.com"),
            .invalidRequestConfiguration("missing path"),
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
            .nonHTTPResponse(URLResponse()),
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
            .responseTooLarge(limit: 1024, observed: 4096),
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
            NetworkError.invalidBaseURL("ftp://example.com")
                .errorDescription?.contains("ftp://example.com") == true
        )
        #expect(
            NetworkError.invalidRequestConfiguration("missing path")
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
        let big = NetworkError.responseTooLarge(limit: 1024, observed: 4096)
            .errorDescription ?? ""
        #expect(big.contains("4096"))
        #expect(big.contains("1024"))
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

    /// Every key in the Korean catalogue must also resolve in English so a
    /// missing translation never silently falls back to the key itself.
    private static let translatedKeys: [String] = [
        "NetworkError.invalidBaseURL",
        "NetworkError.invalidRequestConfiguration",
        "NetworkError.decoding",
        "NetworkError.statusCode",
        "NetworkError.nonHTTPResponse",
        "NetworkError.cancelled",
        "NetworkError.timeout.request",
        "NetworkError.timeout.resource",
        "NetworkError.timeout.connection",
        "NetworkError.responseTooLarge",
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

    @Test("Korean strings contain Hangul code points")
    func koreanStringsAreHangul() {
        // Sample a handful of representative keys; every Korean translation
        // must include at least one Hangul Syllable (U+AC00…U+D7A3).
        let sampledKeys = [
            "NetworkError.statusCode",
            "NetworkError.cancelled",
            "NetworkError.timeout.request",
            "NetworkError.trust.missingServerTrust",
        ]
        for key in sampledKeys {
            let value = _localizedNetworkErrorString(forKey: key, localization: "ko") ?? ""
            let hasHangul = value.unicodeScalars.contains { scalar in
                (0xAC00...0xD7A3).contains(scalar.value)
            }
            #expect(hasHangul, "Korean string for \(key) lacks Hangul: \(value)")
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
}
