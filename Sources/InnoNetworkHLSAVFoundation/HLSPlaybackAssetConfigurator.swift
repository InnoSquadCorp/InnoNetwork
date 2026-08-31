import AVFoundation

/// Controls AVFoundation Common Media Client Data request headers.
public enum HLSCommonMediaClientDataPolicy: Equatable, Sendable {
    /// Keeps AVFoundation's default behavior and sends no CMCD headers.
    case disabled

    /// Asks AVFoundation to attach supported CMCD fields as request headers.
    case enabled
}

/// The effective Common Media Client Data state after configuration.
public enum HLSCommonMediaClientDataStatus: Equatable, Sendable {
    /// AVFoundation will attach supported CMCD request headers.
    case enabled

    /// CMCD request headers are disabled.
    case disabled

    /// The operating system cannot enable AVFoundation CMCD headers.
    case unavailable
}

/// Applies asset-level HLS preferences to a caller-owned `AVURLAsset`.
///
/// The configurator does not create, retain, load, or play the asset.
@MainActor
public struct HLSPlaybackAssetConfigurator {
    /// Creates a stateless playback-asset configurator.
    public init() {}

    /// Applies Common Media Client Data policy before asset loading begins.
    ///
    /// AVFoundation owns the generated header names and values. Enabling the
    /// policy on an unsupported operating system returns `.unavailable`
    /// without mutating the asset.
    @discardableResult
    public func apply(
        _ policy: HLSCommonMediaClientDataPolicy = .disabled,
        to asset: AVURLAsset
    ) -> HLSCommonMediaClientDataStatus {
        #if os(watchOS)
        return Self.resolvedStatus(
            for: policy,
            isSupported: false
        )
        #else
        if #available(macOS 15, iOS 18, tvOS 18, visionOS 2, *) {
            let isEnabled = policy == .enabled
            asset.resourceLoader
                .sendsCommonMediaClientDataAsHTTPHeaders = isEnabled
            return Self.resolvedStatus(
                for: policy,
                isSupported: true
            )
        }
        return Self.resolvedStatus(
            for: policy,
            isSupported: false
        )
        #endif
    }

    nonisolated static func resolvedStatus(
        for policy: HLSCommonMediaClientDataPolicy,
        isSupported: Bool
    ) -> HLSCommonMediaClientDataStatus {
        guard isSupported else {
            return policy == .enabled ? .unavailable : .disabled
        }
        return policy == .enabled ? .enabled : .disabled
    }
}
