import CryptoKit
import Foundation


public enum TrustFailureReason: Sendable, Equatable {
    case unsupportedAuthenticationMethod(String)
    case missingServerTrust
    case systemTrustEvaluationFailed
    case hostNotPinned(String)
    case publicKeyExtractionFailed
    case pinMismatch(host: String)
    case custom(String)
}

public protocol TrustEvaluating: Sendable {
    /// Return true when the challenge is trusted.
    func evaluate(challenge: URLAuthenticationChallenge) -> Bool
}

public struct PublicKeyPinningPolicy: Sendable {
    public let pinsByHost: [String: Set<String>]
    public let includesSubdomains: Bool
    public let allowDefaultEvaluationForUnpinnedHosts: Bool

    public init(
        pinsByHost: [String: Set<String>],
        includesSubdomains: Bool = true,
        allowDefaultEvaluationForUnpinnedHosts: Bool = true
    ) {
        self.pinsByHost = pinsByHost
        self.includesSubdomains = includesSubdomains
        self.allowDefaultEvaluationForUnpinnedHosts = allowDefaultEvaluationForUnpinnedHosts
    }

    func pins(forHost host: String) -> Set<String>? {
        let normalizedHost = host.lowercased()
        var matches: [Set<String>] = []
        for (configuredHost, configuredPins) in pinsByHost {
            let normalizedConfiguredHost = configuredHost.lowercased()
            if normalizedHost == normalizedConfiguredHost {
                matches.append(configuredPins)
                continue
            }
            if includesSubdomains, normalizedHost.hasSuffix(".\(normalizedConfiguredHost)") {
                matches.append(configuredPins)
            }
        }

        guard !matches.isEmpty else { return nil }
        return matches.reduce(into: Set<String>()) { partialResult, next in
            partialResult.formUnion(next)
        }
    }
}

/// Controls how TLS trust challenges are evaluated for outbound requests.
public enum TrustPolicy: Sendable {
    case systemDefault
    case publicKeyPinning(PublicKeyPinningPolicy)
    case custom(any TrustEvaluating)

    var isSystemDefault: Bool {
        if case .systemDefault = self {
            return true
        }
        return false
    }
}

enum TrustChallengeDisposition {
    case performDefaultHandling
    case useCredential(URLCredential)
    case cancel(TrustFailureReason)
}

enum TrustEvaluationError: Error {
    case failed(TrustFailureReason, Error?)
}

enum TrustEvaluator {
    static func evaluate(
        challenge: URLAuthenticationChallenge,
        policy: TrustPolicy
    ) -> TrustChallengeDisposition {
        switch policy {
        case .systemDefault:
            return .performDefaultHandling
        case .custom(let evaluator):
            let trusted = evaluator.evaluate(challenge: challenge)
            if trusted {
                if let trust = challenge.protectionSpace.serverTrust {
                    return .useCredential(URLCredential(trust: trust))
                }
                return .performDefaultHandling
            }
            return .cancel(.custom("Custom trust evaluator rejected the challenge."))
        case .publicKeyPinning(let pinningPolicy):
            return evaluatePublicKeyPinning(challenge: challenge, policy: pinningPolicy)
        }
    }

    private static func evaluatePublicKeyPinning(
        challenge: URLAuthenticationChallenge,
        policy: PublicKeyPinningPolicy
    ) -> TrustChallengeDisposition {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodServerTrust else {
            return .cancel(.unsupportedAuthenticationMethod(method))
        }

        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            return .cancel(.missingServerTrust)
        }

        guard SecTrustEvaluateWithError(serverTrust, nil) else {
            return .cancel(.systemTrustEvaluationFailed)
        }

        let host = challenge.protectionSpace.host.lowercased()
        guard let expectedPins = policy.pins(forHost: host) else {
            if policy.allowDefaultEvaluationForUnpinnedHosts {
                return .performDefaultHandling
            }
            return .cancel(.hostNotPinned(host))
        }

        let extractedPins = extractPublicKeyPins(from: serverTrust)
        guard !extractedPins.isEmpty else {
            return .cancel(.publicKeyExtractionFailed)
        }

        let hasMatch = !expectedPins.isDisjoint(with: extractedPins)
        if hasMatch {
            return .useCredential(URLCredential(trust: serverTrust))
        }

        return .cancel(.pinMismatch(host: host))
    }

    private static func extractPublicKeyPins(from trust: SecTrust) -> Set<String> {
        var pins = Set<String>()
        guard let certificateChain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            return pins
        }

        for certificate in certificateChain {
            guard let key = SecCertificateCopyKey(certificate),
                  let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data?
            else { continue }

            pins.formUnion(pinHashes(for: keyData))

            let keyAttributes = (SecKeyCopyAttributes(key) as? [CFString: Any]) ?? [:]
            let keyType = (keyAttributes[kSecAttrKeyType] as? String) ?? ""
            let keySizeInBits = (keyAttributes[kSecAttrKeySizeInBits] as? Int) ?? 0
            if let spkiData = spkiData(
                publicKeyData: keyData,
                keyType: keyType,
                keySizeInBits: keySizeInBits
            ) {
                pins.formUnion(pinHashes(for: spkiData))
            }
        }
        return pins
    }

    static func spkiData(
        publicKeyData: Data,
        keyType: String,
        keySizeInBits: Int
    ) -> Data? {
        guard let algorithmIdentifier = algorithmIdentifierData(
            keyType: keyType,
            keySizeInBits: keySizeInBits
        ) else {
            return nil
        }

        let subjectPublicKey = derBitString(publicKeyData)
        return derSequence(algorithmIdentifier + subjectPublicKey)
    }

    private static func pinHashes(for bytes: Data) -> Set<String> {
        let digest = SHA256.hash(data: bytes)
        let hashValue = Data(digest).base64EncodedString()
        return [hashValue, "sha256/\(hashValue)"]
    }

    private static func algorithmIdentifierData(
        keyType: String,
        keySizeInBits: Int
    ) -> Data? {
        let rsaKeyType = kSecAttrKeyTypeRSA as String
        let ecPrimeRandomKeyType = kSecAttrKeyTypeECSECPrimeRandom as String
        let ecKeyType = kSecAttrKeyTypeEC as String

        switch keyType {
        case rsaKeyType:
            // rsaEncryption OID (1.2.840.113549.1.1.1) + NULL params
            return Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        case ecPrimeRandomKeyType, ecKeyType:
            // id-ecPublicKey OID (1.2.840.10045.2.1) + named curve OID
            if keySizeInBits <= 256 {
                // prime256v1 (1.2.840.10045.3.1.7)
                return Data([0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07])
            } else if keySizeInBits <= 384 {
                // secp384r1 (1.3.132.0.34)
                return Data([0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22])
            } else {
                // secp521r1 (1.3.132.0.35)
                return Data([0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x23])
            }
        default:
            return nil
        }
    }

    private static func derSequence(_ payload: Data) -> Data {
        derWrap(tag: 0x30, payload: payload)
    }

    private static func derBitString(_ payload: Data) -> Data {
        // First byte is the number of unused bits in the final octet (0 for full bytes).
        var bitPayload = Data([0x00])
        bitPayload.append(payload)
        return derWrap(tag: 0x03, payload: bitPayload)
    }

    private static func derWrap(tag: UInt8, payload: Data) -> Data {
        var result = Data([tag])
        result.append(derLength(payload.count))
        result.append(payload)
        return result
    }

    private static func derLength(_ count: Int) -> Data {
        precondition(count >= 0)
        if count < 0x80 {
            return Data([UInt8(count)])
        }

        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }

        var result = Data([0x80 | UInt8(bytes.count)])
        result.append(contentsOf: bytes)
        return result
    }
}
