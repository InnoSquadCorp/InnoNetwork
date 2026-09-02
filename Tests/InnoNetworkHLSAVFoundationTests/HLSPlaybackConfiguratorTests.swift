#if canImport(AVFoundation)
import AVFoundation
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS playback configuration")
struct HLSPlaybackConfiguratorTests {
    @Test("configuration packs normalize unsafe numeric input")
    func configurationNormalization() {
        let variant = HLSPlaybackVariantPack(
            maximumPeakBitRate: -1,
            maximumPeakBitRateForExpensiveNetworks: 0,
            maximumWidth: 1_920,
            maximumHeight: 1_080,
            maximumWidthForExpensiveNetworks: -2,
            maximumHeightForExpensiveNetworks: 720
        )
        #expect(variant.maximumPeakBitRate == nil)
        #expect(
            variant.maximumPeakBitRateForExpensiveNetworks == nil
        )
        #expect(variant.maximumWidth == 1_920)
        #expect(variant.maximumHeight == 1_080)
        #expect(variant.maximumWidthForExpensiveNetworks == nil)
        #expect(
            variant.maximumHeightForExpensiveNetworks == nil
        )
        let constrained = HLSPlaybackVariantPack(
            maximumPeakBitRate: 2_000_000,
            maximumPeakBitRateForExpensiveNetworks: 4_000_000,
            maximumWidth: 1_280,
            maximumHeight: 720,
            maximumWidthForExpensiveNetworks: 1_920,
            maximumHeightForExpensiveNetworks: 1_080
        )
        #expect(
            constrained.maximumPeakBitRateForExpensiveNetworks
                == 2_000_000
        )
        #expect(
            constrained.maximumWidthForExpensiveNetworks == 1_280
        )
        #expect(
            constrained.maximumHeightForExpensiveNetworks == 720
        )
        #expect(
            HLSPlaybackLivePack(
                timeOffsetFromLive: .nan
            ).timeOffsetFromLive == nil
        )
        #expect(
            HLSPlaybackLivePack(
                timeOffsetFromLive: -1
            ).timeOffsetFromLive == nil
        )
        #expect(
            HLSPlaybackLivePack(
                timeOffsetFromLive: 3
            ).timeOffsetFromLive == 3
        )
    }

    @Test("media commands reject empty and conflicting preferences")
    func mediaCommandValidation() {
        #expect(
            throws:
                HLSPlaybackConfigurationError
                .emptyMediaPreference(.audio)
        ) {
            try HLSPlaybackConfigurator.validate([
                .preferred(
                    .audio,
                    HLSPlaybackMediaPreference()
                )
            ])
        }
        #expect(
            throws:
                HLSPlaybackConfigurationError
                .conflictingMediaSelections(
                    .subtitles,
                    .closedCaptions
                )
        ) {
            try HLSPlaybackConfigurator.validate([
                .automatic(.subtitles),
                .disabled(.closedCaptions),
            ])
        }
    }

    @MainActor
    @Test("scalar configuration is applied without taking player ownership")
    func appliesScalarConfiguration() async throws {
        let item = AVPlayerItem(
            url: try #require(
                URL(string: "https://media.example/live.m3u8")
            )
        )
        let configuration = HLSPlaybackConfiguration.advanced(
            variant: HLSPlaybackVariantPack(
                maximumPeakBitRate: 4_000_000,
                maximumPeakBitRateForExpensiveNetworks: 1_500_000,
                maximumWidth: 1_920,
                maximumHeight: 1_080,
                maximumWidthForExpensiveNetworks: 1_280,
                maximumHeightForExpensiveNetworks: 720,
                permitsLosslessAudio: true,
                startsOnFirstEligibleVariant: true
            ),
            live: HLSPlaybackLivePack(timeOffsetFromLive: 3),
            interstitialPolicy: .disabled
        )

        let result = try await HLSPlaybackConfigurator().apply(
            configuration,
            to: item
        )

        #expect(result.mediaSelections.isEmpty)
        #expect(item.preferredPeakBitRate == 4_000_000)
        #expect(
            item.preferredPeakBitRateForExpensiveNetworks
                == 1_500_000
        )
        #if !os(watchOS)
        #expect(item.preferredMaximumResolution.width == 1_920)
        #expect(item.preferredMaximumResolution.height == 1_080)
        #expect(
            item.preferredMaximumResolutionForExpensiveNetworks.width
                == 1_280
        )
        #expect(
            item.preferredMaximumResolutionForExpensiveNetworks.height
                == 720
        )
        #endif
        #expect(item.startsOnFirstEligibleVariant)
        #expect(
            item.variantPreferences.contains(
                .scalabilityToLosslessAudio
            )
        )
        #expect(item.configuredTimeOffsetFromLive.seconds == 3)
        #expect(!item.automaticallyHandlesInterstitialEvents)
    }

    @Test("language matching is deterministic and BCP 47 compatible")
    @available(
        macOS 26,
        iOS 26,
        tvOS 26,
        watchOS 26,
        visionOS 26,
        *
    )
    func languageMatching() {
        #expect(
            HLSPlaybackConfigurator.preferredLanguage(
                "en_US",
                available: ["fr", "en-US", "en-GB"]
            ) == "en-US"
        )
        #expect(
            HLSPlaybackConfigurator.preferredLanguage(
                "en",
                available: ["fr", "en-GB"]
            ) == "en-GB"
        )
        #expect(
            HLSPlaybackConfigurator.preferredLanguage(
                "ko",
                available: ["fr", "en"]
            ) == nil
        )
    }

    @Test("configuration errors expose localized recovery")
    func localizedConfigurationErrors() {
        let error =
            HLSPlaybackConfigurationError
            .mediaSelectionUnavailable(.audio)
        #expect(!error.localizedDescription.isEmpty)
        #expect(error.recoverySuggestion?.isEmpty == false)
    }
}
#endif
