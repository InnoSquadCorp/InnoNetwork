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
