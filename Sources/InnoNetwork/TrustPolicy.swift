import Foundation

public enum TrustFailureReason: Sendable, Equatable {
    case unsupportedAuthenticationMethod(String)
    case missingServerTrust
    /// The system trust evaluation rejected the chain. The associated
    /// `reason` carries the localized description from
    /// `SecTrustEvaluateWithError`'s out-error when one was produced — it is
    /// `nil` only when Security.framework reports failure without populating
    /// an error (rare in practice). Surface this through metrics/logging so
    /// production failures distinguish "expired leaf" from "untrusted root"
    /// instead of collapsing every TLS reject onto a single bucket.
    case systemTrustEvaluationFailed(reason: String?)
    case hostNotPinned(String)
    case publicKeyExtractionFailed
    case pinMismatch(host: String)
    case custom(String)
}

/// Outcome of a custom trust challenge evaluation.
///
/// Returned by ``TrustEvaluating/evaluate(challenge:)`` so custom
/// evaluators can surface granular failure reasons (e.g. pin mismatch
/// vs. host not pinned) instead of collapsing every reject onto a
/// single ``TrustFailureReason/custom(_:)`` string.
public enum TrustChallengeOutcome: Sendable {
    /// Defer to URLSession's default trust evaluation.
    case performDefaultHandling
    /// Accept the challenge and use the credential built from the
    /// challenge's `serverTrust`. If `serverTrust` is `nil`, the
    /// evaluator falls through to default handling.
    case useCredential
    /// Cancel the challenge with the supplied reason. The reason is
    /// surfaced through ``NetworkError/trustEvaluationFailed(_:)``.
    case cancel(TrustFailureReason)
}

public protocol TrustEvaluating: Sendable {
    /// Evaluate a TLS authentication challenge.
    ///
    /// Returning ``TrustChallengeOutcome/cancel(_:)`` with a structured
    /// ``TrustFailureReason`` is preferred over collapsing failures onto
    /// ``TrustFailureReason/custom(_:)`` so that telemetry can distinguish
    /// trust failure modes.
    func evaluate(challenge: URLAuthenticationChallenge) -> TrustChallengeOutcome
}

/// Controls how TLS trust challenges are evaluated for outbound requests.
///
/// Public-key pinning evaluators live in the ``InnoNetworkTrust`` product
/// — `import InnoNetworkTrust` and wrap the policy with
/// `PublicKeyPinningEvaluator(policy:)` then pass it via
/// ``TrustPolicy/custom(_:)``.
public enum TrustPolicy: Sendable {
    case systemDefault
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
            switch evaluator.evaluate(challenge: challenge) {
            case .performDefaultHandling:
                return .performDefaultHandling
            case .useCredential:
                if let trust = challenge.protectionSpace.serverTrust {
                    return .useCredential(URLCredential(trust: trust))
                }
                return .cancel(.missingServerTrust)
            case .cancel(let reason):
                return .cancel(reason)
            }
        }
    }
}
