#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation

/// Controls session-wide FairPlay advisory-key caching.
///
/// Advisory keys are available on iOS 27 and newer outside Mac Catalyst.
/// Unsupported environments reject the enabled policy during session setup.
public enum HLSFairPlayAdvisoryKeyPolicy: Equatable, Sendable {
    /// Preserves the standard SPC-to-CKC exchange for every key request.
    case disabled

    /// Enables advisory keys for a streaming-only content-key session.
    ///
    /// Advisory keys are incompatible with persistable-key acquisition on the
    /// same session because every request must use the optional streaming SPC
    /// API. Use a separate ``HLSFairPlaySession`` for offline key workflows.
    case enabledForStreamingOnly
}

enum HLSFairPlayAdvisoryKeyPolicyFailure: Equatable {
    case unavailable
}

enum HLSFairPlayAdvisoryKeySupport {
    static var isAvailable: Bool {
        #if compiler(>=6.4) && os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 27, *) {
            return true
        }
        #endif
        return false
    }

    static func validationFailure(
        for policy: HLSFairPlayAdvisoryKeyPolicy,
        isSupported: Bool
    ) -> HLSFairPlayAdvisoryKeyPolicyFailure? {
        switch policy {
        case .disabled:
            return nil
        case .enabledForStreamingOnly:
            return isSupported ? nil : .unavailable
        }
    }

    @MainActor
    static func configure(
        _ policy: HLSFairPlayAdvisoryKeyPolicy,
        on session: AVContentKeySession
    ) throws {
        guard
            validationFailure(
                for: policy,
                isSupported: isAvailable
            ) == nil
        else {
            throw HLSFairPlaySessionError.advisoryKeysUnavailable
        }
        guard policy == .enabledForStreamingOnly else {
            return
        }

        #if compiler(>=6.4) && os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 27, *) {
            session.supportsAdvisoryKeys = true
            return
        }
        #endif
        throw HLSFairPlaySessionError.advisoryKeysUnavailable
    }
}

extension HLSFairPlayAdvisoryKeyPolicyFailure: Error {}
#endif
