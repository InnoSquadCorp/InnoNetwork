import Foundation
import Security
import Testing

@testable import InnoNetwork
@testable import InnoNetworkTrust

@Suite("Trust Evaluation Tests")
struct TrustEvaluationTests {

    @Test("Public key pinning policy unions subdomains and exact hosts by default")
    func pinningPolicyUnionHostMatching() {
        let policy = PublicKeyPinningPolicy(
            pinsByHost: [
                "api.example.com": ["sha256/primary-pin"],
                "example.com": ["sha256/backup-pin"],
            ],
            includesSubdomains: true
        )

        let exactHostPins = policy.pins(forHost: "api.example.com")
        #expect(exactHostPins == Set(["sha256/primary-pin", "sha256/backup-pin"]))

        let subdomainPins = policy.pins(forHost: "mobile.api.example.com")
        #expect(subdomainPins == Set(["sha256/primary-pin", "sha256/backup-pin"]))

        #expect(policy.pins(forHost: "unrelated.domain") == nil)
    }

    @Test("DNS root dots cannot bypass configured pins in either host spelling")
    func pinningPolicyRootDotMatching() {
        let policy = PublicKeyPinningPolicy(
            pinsByHost: [
                "API.Example.com.": ["sha256/api-pin"],
                "example.com": ["sha256/parent-pin"],
            ]
        )
        #expect(policy.pins(forHost: "api.example.com") == Set(["sha256/api-pin", "sha256/parent-pin"]))
        #expect(policy.pins(forHost: "API.EXAMPLE.COM.") == Set(["sha256/api-pin", "sha256/parent-pin"]))
        #expect(policy.pins(forHost: "mobile.api.example.com.") == Set(["sha256/api-pin", "sha256/parent-pin"]))
        #expect(policy.pins(forHost: "notapi.example.com.") == Set(["sha256/parent-pin"]))
        #expect(policy.pins(forHost: "api.example.com..") == nil)
    }

    @Test("Root dot matching preserves strict, most-specific and IP-literal policy")
    func pinningPolicyRootDotControls() {
        let strict = PublicKeyPinningPolicy(
            pinsByHost: ["api.example.com": ["sha256/api-pin"]],
            includesSubdomains: false,
            allowDefaultEvaluationForUnpinnedHosts: false,
            hostMatchingStrategy: .mostSpecificHost
        )
        #expect(strict.pins(forHost: "API.example.com.") == Set(["sha256/api-pin"]))
        #expect(strict.pins(forHost: "child.api.example.com.") == nil)

        let literals = PublicKeyPinningPolicy(
            pinsByHost: ["127.0.0.1": ["sha256/ipv4"], "::1": ["sha256/ipv6"]]
        )
        #expect(literals.pins(forHost: "127.0.0.1") == Set(["sha256/ipv4"]))
        #expect(literals.pins(forHost: "127.0.0.1.") == Set(["sha256/ipv4"]))
        #expect(literals.pins(forHost: "::1") == Set(["sha256/ipv6"]))
    }

    @Test(
        "A CA-valid root-dot challenge still enforces an incorrect pin",
        arguments: ["api.example.test", "api.example.test."]
    )
    func rootDotChallengeEnforcesPin(host: String) throws {
        let leafData = try #require(
            Data(base64Encoded: trustFixtureLeafDER, options: .ignoreUnknownCharacters)
        )
        let caData = try #require(
            Data(base64Encoded: trustFixtureCADer, options: .ignoreUnknownCharacters)
        )
        let leaf = try #require(SecCertificateCreateWithData(nil, leafData as CFData))
        let anchor = try #require(SecCertificateCreateWithData(nil, caData as CFData))
        var trust: SecTrust?
        #expect(
            SecTrustCreateWithCertificates(
                leaf, SecPolicyCreateSSL(true, host as CFString), &trust
            ) == errSecSuccess
        )
        let serverTrust = try #require(trust)
        #expect(SecTrustSetAnchorCertificates(serverTrust, [anchor] as CFArray) == errSecSuccess)
        #expect(SecTrustSetAnchorCertificatesOnly(serverTrust, true) == errSecSuccess)
        // The short-lived fixture is evaluated at a fixed point inside its
        // validity window, so this regression remains deterministic after it
        // expires in the wall clock.
        #expect(
            SecTrustSetVerifyDate(
                serverTrust, Date(timeIntervalSince1970: 1_790_208_000) as CFDate
            ) == errSecSuccess
        )
        #expect(SecTrustEvaluateWithError(serverTrust, nil))

        let protectionSpace = PinningFixtureProtectionSpace(host: host, trust: serverTrust)
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: PinningFixtureChallengeSender()
        )
        let policy = PublicKeyPinningPolicy(
            pinsByHost: ["api.example.test": ["sha256/intentionally-wrong-pin"]]
        )
        let outcome = PublicKeyPinningEvaluator(policy: policy).evaluate(challenge: challenge)
        guard case .cancel(.pinMismatch) = outcome else {
            Issue.record("CA-valid host must fail its configured pin, not use default handling")
            return
        }
    }

    @Test("Public key pinning policy can prefer the most specific host")
    func pinningPolicyMostSpecificHostMatching() {
        let policy = PublicKeyPinningPolicy(
            pinsByHost: [
                "api.example.com": ["sha256/api-pin"],
                "example.com": ["sha256/root-pin"],
                "internal.example.com": ["sha256/internal-pin"],
            ],
            includesSubdomains: true,
            hostMatchingStrategy: .mostSpecificHost
        )

        let exactHostPins = policy.pins(forHost: "api.example.com")
        #expect(exactHostPins == Set(["sha256/api-pin"]))

        let nestedHostPins = policy.pins(forHost: "mobile.internal.example.com")
        #expect(nestedHostPins == Set(["sha256/internal-pin"]))

        let rootSubdomainPins = policy.pins(forHost: "cdn.example.com")
        #expect(rootSubdomainPins == Set(["sha256/root-pin"]))

        #expect(policy.pins(forHost: "unrelated.domain") == nil)
    }

    @Test("Most-specific pinning still ignores parent domains when subdomains are disabled")
    func pinningPolicyMostSpecificHonorsSubdomainSetting() {
        let policy = PublicKeyPinningPolicy(
            pinsByHost: [
                "example.com": ["sha256/root-pin"]
            ],
            includesSubdomains: false,
            hostMatchingStrategy: .mostSpecificHost
        )

        #expect(policy.pins(forHost: "example.com") == Set(["sha256/root-pin"]))
        #expect(policy.pins(forHost: "api.example.com") == nil)
    }

    @Test("Public key pinning rejects unsupported authentication method")
    func unsupportedAuthMethodRejected() {
        let challenge = makeTrustObservabilityChallenge(
            host: "api.example.com",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let evaluator = PublicKeyPinningEvaluator(
            policy: PublicKeyPinningPolicy(
                pinsByHost: ["api.example.com": ["sha256/primary-pin"]],
                allowDefaultEvaluationForUnpinnedHosts: false
            )
        )

        let result = TrustEvaluator.evaluate(challenge: challenge, policy: .custom(evaluator))
        switch result {
        case .cancel(.unsupportedAuthenticationMethod(let method)):
            #expect(method == NSURLAuthenticationMethodHTTPBasic)
        default:
            Issue.record("Expected unsupported authentication method to be rejected.")
        }
    }

    @Test("Custom trust evaluator can reject or accept challenge")
    func customTrustEvaluatorPath() {
        let challenge = makeTrustObservabilityChallenge(
            host: "api.example.com",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )

        let rejected = TrustEvaluator.evaluate(
            challenge: challenge,
            policy: .custom(RejectingTrustEvaluator())
        )
        switch rejected {
        case .cancel(.custom(let message)):
            #expect(message.contains("rejected"))
        default:
            Issue.record("Expected custom evaluator rejection to cancel trust evaluation.")
        }

        let accepted = TrustEvaluator.evaluate(
            challenge: challenge,
            policy: .custom(AcceptingTrustEvaluator())
        )
        switch accepted {
        case .cancel(.missingServerTrust):
            #expect(Bool(true))
        default:
            Issue.record(
                "Expected custom evaluator acceptance to fail-secure with .missingServerTrust when serverTrust is absent."
            )
        }
    }

    @Test("SPKI helper supports common key types")
    func spkiEncodingHelperSupportsCommonKeyTypes() {
        let keyData = Data([0x01, 0x02, 0x03, 0x04, 0x05])

        let rsa = PublicKeyPinningEvaluator.spkiData(
            publicKeyData: keyData,
            keyType: kSecAttrKeyTypeRSA as String,
            keySizeInBits: 2048
        )
        #expect(rsa != nil)
        #expect((rsa?.count ?? 0) > keyData.count)

        let p256 = PublicKeyPinningEvaluator.spkiData(
            publicKeyData: keyData,
            keyType: kSecAttrKeyTypeECSECPrimeRandom as String,
            keySizeInBits: 256
        )
        #expect(p256 != nil)
        #expect((p256?.count ?? 0) > keyData.count)

        let unsupported = PublicKeyPinningEvaluator.spkiData(
            publicKeyData: keyData,
            keyType: "com.innonetwork.unsupported",
            keySizeInBits: 0
        )
        #expect(unsupported == nil)
    }

    @Test("SPKI helper recognizes Ed25519 by OID")
    func spkiEncodingHelperSupportsEd25519OID() {
        // Ed25519 public keys are always 32 bytes per RFC 8032; use a fixed
        // test vector so the SPKI bytes are deterministic.
        let publicKey = Data(repeating: 0x00, count: 32)
        let spki = PublicKeyPinningEvaluator.spkiData(
            publicKeyData: publicKey,
            keyType: "1.3.101.112",
            keySizeInBits: 256
        )

        // Expected DER from RFC 8410 §4 example: 12 prefix bytes + 32 key bytes.
        let expected: [UInt8] =
            [
                0x30, 0x2a,  // outer SEQUENCE, 42 content bytes
                0x30, 0x05,  // AlgorithmIdentifier SEQUENCE, 5 content bytes
                0x06, 0x03, 0x2b, 0x65, 0x70,  // OID 1.3.101.112 (id-Ed25519)
                0x03, 0x21, 0x00,  // BIT STRING, 33 bytes (0 unused + 32 key)
            ] + Array(repeating: UInt8(0x00), count: 32)
        #expect(spki == Data(expected))
    }

    /// CONTRACT LOCK — Ed25519 identification is OID-only.
    ///
    /// Informal `"ed25519"` / `"Ed25519"` / `"ED25519"` keyType strings
    /// produced by private CAs must not match: the loose word match was
    /// dropped to avoid colliding with a future Security.framework
    /// constant that happens to embed the substring.
    @Test(
        "SPKI helper rejects Ed25519 keyword variants",
        arguments: ["ed25519", "Ed25519", "ED25519", "ed-25519"]
    )
    func spkiEncodingHelperRejectsEd25519Keywords(keyType: String) {
        let publicKey = Data(repeating: 0x00, count: 32)
        let result = PublicKeyPinningEvaluator.spkiData(
            publicKeyData: publicKey,
            keyType: keyType,
            keySizeInBits: 256
        )
        #expect(result == nil, "informal Ed25519 keyword must not be recognised; require the OID")
    }

    @Test("SPKI helper still returns nil for unknown algorithm strings")
    func spkiEncodingHelperRejectsUnknownAlgorithm() {
        let publicKey = Data(repeating: 0x00, count: 32)
        let unsupported = PublicKeyPinningEvaluator.spkiData(
            publicKeyData: publicKey,
            keyType: "rsa-pss-pq-future-curve",
            keySizeInBits: 2048
        )
        #expect(unsupported == nil)
    }

    /// CONTRACT LOCK — `PinScope` default and surface.
    ///
    /// Adopters relying on the historical "match anywhere in the chain"
    /// behaviour must keep getting `.anyInChain` when they omit
    /// `pinScope`. Switching the default to `.leafOnly` would silently
    /// reject every existing pin set whose CA-issued intermediates
    /// rotate while the leaf remains the same — a behaviour change
    /// without a code change. Conversely, callers who opt into
    /// `.leafOnly` must see the value preserved on the policy so the
    /// extractor narrows the hashed chain accordingly. Lock both
    /// halves of that contract.
    @Test("PublicKeyPinningPolicy preserves pinScope and defaults to anyInChain")
    func pinningPolicyPinScopeRoundTrip() {
        let defaultScope = PublicKeyPinningPolicy(
            pinsByHost: ["api.example.com": ["sha256/leaf-pin"]]
        )
        #expect(defaultScope.pinScope == .anyInChain)

        let leafOnly = PublicKeyPinningPolicy(
            pinsByHost: ["api.example.com": ["sha256/leaf-pin"]],
            pinScope: .leafOnly
        )
        #expect(leafOnly.pinScope == .leafOnly)

        let anyInChain = PublicKeyPinningPolicy(
            pinsByHost: ["api.example.com": ["sha256/leaf-pin"]],
            pinScope: .anyInChain
        )
        #expect(anyInChain.pinScope == .anyInChain)
    }
}

private let trustFixtureLeafDER = """
    MIIDUjCCAjqgAwIBAgICBNIwDQYJKoZIhvcNAQELBQAwJzElMCMGA1UEAwwcSW5ub05ldHdv
    cmsgQXVkaXQgRml4dHVyZSBDQTAeFw0yNjA5MjMwNDM4MjlaFw0yNjA5MjUwNDM4MjlaMBsx
    GTAXBgNVBAMMEGFwaS5leGFtcGxlLnRlc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEK
    AoIBAQC1rtswuxBZ94o02MhFyOehZyYwWe4O31u8K63rVkcvAN0vxOUVt14ZBdukSkSeYpnd
    xwWnCvE/16CXwxUhpIVG2nd1iVdEBgjt23ZSgJEKZ1tkyfHbjBXpY+77s7TylrVJUUGcIYxx
    UE+0GSBn3K1rJfzE0d6XV1z/AAEo2eeqao1xb65Ay/EEft0kdhqOuI6goSWkXQzPTyIjcs2d
    6IomwgBI0eOGFjH98WIj+qSJuZGGbUoGzPadQ+k6teDRZhsZLcTS9h77o+nllQSkm2CLHgFU
    NBwddp3FDMDraD72NuM87VbPUEvJ0hCpiq+LH6qLVJDFfApy9AO/uXANnV9fAgMBAAGjgZMw
    gZAwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwEw
    GwYDVR0RBBQwEoIQYXBpLmV4YW1wbGUudGVzdDAdBgNVHQ4EFgQUJ4/gaXudv945TaJ7LPrV
    5l29SgswHwYDVR0jBBgwFoAUJ1F7AkNh7U3AH2ke4WFsoUXpAdwwDQYJKoZIhvcNAQELBQAD
    ggEBAApWbl1IIHK7XTQXGe4dYSq76GQN/o4XHsVij7cQ4YAYQNKaNTOC9+waHFQpf2sgLr+I
    xUkBwAvF7g0qMiYhtJUgLf1x3hWe9ufFp3zHl+RigEPj0HWpYEnGLhP5UgXCdCh7cDsoDAh2
    cFlY9zY7GmabuZLnB4B3S7OtFue8i9Nqg+ox81Xoqu+9Xr5s4lY58Lt9RKybmMPLsHzonSZf
    VAVnJwfBvE5kiyWI9yx0XADdgm3hLSgRyEVEX9lhiFzEmPi9tbrPlMoSImr+IIQLLIYn8fFG
    6mYDerZzTgS/pGPakG6kAo+rxeXIZufT/QgTqCswNENDXwLNKCHCQC5xkCU=
    """
private let trustFixtureCADer = """
    MIIDPzCCAiegAwIBAgIUZo12C1FlPk1WTKrvB0IG7vSg9qgwDQYJKoZIhvcNAQELBQAwJzEl
    MCMGA1UEAwwcSW5ub05ldHdvcmsgQXVkaXQgRml4dHVyZSBDQTAeFw0yNjA5MjMwNDM4Mjha
    Fw0yNjA5MjUwNDM4MjhaMCcxJTAjBgNVBAMMHElubm9OZXR3b3JrIEF1ZGl0IEZpeHR1cmUg
    Q0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCEZ6sazCOtLfp49X4U8256qvbN
    IxBTqYpNk+syD2e5dRjbGjJ54UCT61ugE2HT/oyJvWful3wSlYSRU7WfZtgXnaPGSyTsAH89
    QHEEk0vMmE46GeMEq42jD5BgYoX13/wGDJwydm1yeQSclwMEQgnarYyi7wWnLReocwUgN4nd
    s/3PvRSlBJeqZf+DKhNbvJdKKs21otatfUE56zJc9STmmuL45ZYI8+kblBwj41M0dBpfl6G5
    Q8PSZNzlFYDyJRsHimB6xOIEIRCH9GnWUxd0bUhI9CTGL5t9gyZJbOujGN1NYJODi0qAaOHX
    k1fjZiZFmOyMrIcsdchQ4Y/ckzmzAgMBAAGjYzBhMB0GA1UdDgQWBBQnUXsCQ2HtTcAfaR7h
    YWyhRekB3DAfBgNVHSMEGDAWgBQnUXsCQ2HtTcAfaR7hYWyhRekB3DAPBgNVHRMBAf8EBTAD
    AQH/MA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQsFAAOCAQEAe9OiNQD6DUe9Xc3YuZnj
    WbcWf9s0vBzM5yr+m0t5rMDYpwcNNMjA3VK3bjgg3v9qzoY+8R+nDOcWbxbIlBrqDCItn2Wv
    4xFQqmtdxjEhynkbX0+GE9eXw8xubkg8KnR5tDjLBlV9Gj5fcuOjTR58i7HnaeBSB7+/imhV
    isIs/3h70diKH/Dhm7POijBZ480MzGC4X9V9UIGPi5feSeiYH7pyTgGV5UIa97TRjVzltMhP
    1OkaRhuNpu+DBiWHNejZal0M6VeSl+z90gJWkcTjwblX5Dw+kdDxzIUg7ALSD0KL1h9SZhDj
    F2N5GSa+ObdeXREs/sEUdxKx7G1f+fIYIQ==
    """

private final class PinningFixtureProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    private let fixtureTrust: SecTrust

    init(host: String, trust: SecTrust) {
        fixtureTrust = trust
        super.init(
            host: host, port: 443, protocol: "https", realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
    }

    required init?(coder: NSCoder) { fatalError("Not used by this test fixture") }

    override var serverTrust: SecTrust? { fixtureTrust }
}

private final class PinningFixtureChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
