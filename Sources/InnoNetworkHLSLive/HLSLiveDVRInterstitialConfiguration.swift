import Foundation
import InnoNetworkHLS

/// Controls whether live DVR retains Apple HLS interstitial media.
public enum HLSLiveDVRInterstitialPolicy: Equatable, Sendable {
    /// Rejects playlists whose retained timeline references interstitial media.
    case disabled

    /// Rewrites interstitial sources to bounded, package-local HLS assets.
    case package
}

/// Controls an unavailable interstitial's effect on live DVR recording.
public enum HLSLiveDVRInterstitialFailurePolicy: Equatable, Sendable {
    /// Fails the recording instead of publishing an incomplete event.
    case failRecording

    /// Omits the complete event and continues recording primary content.
    case omitEvent
}

/// Groups bounded Apple HLS interstitial packaging for live DVR.
///
/// Interstitial packaging is opt-in. Each retained asset becomes its own
/// self-contained offline HLS package so ordered asset-list playback and
/// rendition timelines remain intact.
public struct HLSLiveDVRInterstitialPack: Sendable {
    let policy: HLSLiveDVRInterstitialPolicy
    let failurePolicy: HLSLiveDVRInterstitialFailurePolicy
    let maximumEventCount: Int
    let maximumAssetsPerEvent: Int
    let maximumPlaylistCount: Int
    let maximumMediaResourceBytes: Int
    let maximumTotalBytes: Int64
    let variantSelectionPolicy: HLSVariantSelectionPolicy
    let renditions: HLSOfflineRenditionPack
    let transfer: HLSTransferPack

    /// Creates bounded interstitial packaging behavior.
    ///
    /// Event count is clamped to `1...1,000`, assets per event to
    /// `1...1,000`, retained interstitial playlists to `1...128`, each media
    /// resource to at most 1 GiB, and aggregate interstitial storage to at
    /// most 16 GiB. The live DVR recording's overall media-byte limit remains
    /// authoritative.
    public init(
        policy: HLSLiveDVRInterstitialPolicy = .disabled,
        failurePolicy: HLSLiveDVRInterstitialFailurePolicy =
            .failRecording,
        maximumEventCount: Int = 32,
        maximumAssetsPerEvent: Int = 16,
        maximumPlaylistCount: Int = 128,
        maximumMediaResourceBytes: Int = 128 * 1_024 * 1_024,
        maximumTotalBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        variantSelectionPolicy: HLSVariantSelectionPolicy =
            .highestQuality,
        renditions: HLSOfflineRenditionPack = HLSOfflineRenditionPack(),
        transfer: HLSTransferPack = HLSTransferPack()
    ) {
        self.policy = policy
        self.failurePolicy = failurePolicy
        self.maximumEventCount = min(1_000, max(1, maximumEventCount))
        self.maximumAssetsPerEvent = min(
            1_000,
            max(1, maximumAssetsPerEvent)
        )
        self.maximumPlaylistCount = min(
            128,
            max(1, maximumPlaylistCount)
        )
        self.maximumMediaResourceBytes = min(
            1 * 1_024 * 1_024 * 1_024,
            max(1, maximumMediaResourceBytes)
        )
        self.maximumTotalBytes = min(
            16 * 1_024 * 1_024 * 1_024,
            max(1, maximumTotalBytes)
        )
        self.variantSelectionPolicy = variantSelectionPolicy
        self.renditions = renditions
        self.transfer = transfer
    }
}
