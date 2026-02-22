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
        let certificateCount = SecTrustGetCertificateCount(trust)
        for index in 0..<certificateCount {
            guard let certificate = SecTrustGetCertificateAtIndex(trust, index),
                  let key = SecCertificateCopyKey(certificate),
                  let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data?
            else {
                continue
            }
            let digest = SHA256.hash(data: keyData)
            let hashValue = Data(digest).base64EncodedString()
            pins.insert(hashValue)
            pins.insert("sha256/\(hashValue)")
        }
        return pins
    }
}
