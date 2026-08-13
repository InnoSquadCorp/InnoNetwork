#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation

/// Applies platform-specific interstitial persistence to one download task.
@available(macOS 12, iOS 15, watchOS 10, visionOS 1, *)
enum HLSAssetInterstitialConfiguration {
    @MainActor
    static func apply(
        _ content: HLSAssetDownloadContentPack,
        to configuration: AVAssetDownloadConfiguration
    ) throws {
        guard content.includesInterstitialAssets else {
            return
        }

        // Xcode 26.0.1 imports this API as unavailable for macOS even though
        // the framework header declares macOS 15 support. Keep the feature on
        // newer SDKs while preserving the package's required Xcode 26 build.
        #if os(macOS) && compiler(<6.4)
        throw HLSAssetDownloadSessionError
            .interstitialAssetsUnavailable
        #else
        if #available(macOS 15,
        iOS 18,
        watchOS 11,
        visionOS 2,
        *) {
            configuration.downloadsInterstitialAssets = true
            return
        }
        throw HLSAssetDownloadSessionError
            .interstitialAssetsUnavailable
        #endif
    }
}
#endif
