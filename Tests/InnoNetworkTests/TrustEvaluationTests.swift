import Foundation
import Security
import Testing

@testable import InnoNetwork

@Suite("Trust Evaluation Tests")
struct TrustEvaluationTests {

    @Test("Public key pinning policy matches subdomains and exact hosts")
    func pinningPolicyHostMatching() {
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

    @Test("Public key pinning rejects unsupported authentication method")
    func unsupportedAuthMethodRejected() {
        let challenge = makeTrustObservabilityChallenge(
            host: "api.example.com",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let policy = TrustPolicy.publicKeyPinning(
            PublicKeyPinningPolicy(
                pinsByHost: ["api.example.com": ["sha256/primary-pin"]],
                allowDefaultEvaluationForUnpinnedHosts: false
            )
        )

        let result = TrustEvaluator.evaluate(challenge: challenge, policy: policy)
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
        case .performDefaultHandling:
            #expect(Bool(true))
        default:
            Issue.record(
                "Expected custom evaluator acceptance to continue with default handling when trust is unavailable.")
        }
    }

    @Test("SPKI helper supports common key types")
    func spkiEncodingHelperSupportsCommonKeyTypes() {
        let keyData = Data([0x01, 0x02, 0x03, 0x04, 0x05])

        let rsa = TrustEvaluator.spkiData(
            publicKeyData: keyData,
            keyType: kSecAttrKeyTypeRSA as String,
            keySizeInBits: 2048
        )
        #expect(rsa != nil)
        #expect((rsa?.count ?? 0) > keyData.count)

        let p256 = TrustEvaluator.spkiData(
            publicKeyData: keyData,
            keyType: kSecAttrKeyTypeECSECPrimeRandom as String,
            keySizeInBits: 256
        )
        #expect(p256 != nil)
        #expect((p256?.count ?? 0) > keyData.count)

        let unsupported = TrustEvaluator.spkiData(
            publicKeyData: keyData,
            keyType: "com.innonetwork.unsupported",
            keySizeInBits: 0
        )
        #expect(unsupported == nil)
    }

    @Test(
        "SPKI helper recognizes Ed25519 by name and by OID",
        arguments: ["ed25519", "Ed25519", "ED25519", "1.3.101.112"]
    )
    func spkiEncodingHelperSupportsEd25519(keyType: String) {
        // Ed25519 public keys are always 32 bytes per RFC 8032; use a fixed
        // test vector so the SPKI bytes are deterministic.
        let publicKey = Data(repeating: 0x00, count: 32)
        let spki = TrustEvaluator.spkiData(
            publicKeyData: publicKey,
            keyType: keyType,
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

    @Test("SPKI helper still returns nil for unknown algorithm strings")
    func spkiEncodingHelperRejectsUnknownAlgorithm() {
        let publicKey = Data(repeating: 0x00, count: 32)
        let unsupported = TrustEvaluator.spkiData(
            publicKeyData: publicKey,
            keyType: "rsa-pss-pq-future-curve",
            keySizeInBits: 2048
        )
        #expect(unsupported == nil)
    }
}
