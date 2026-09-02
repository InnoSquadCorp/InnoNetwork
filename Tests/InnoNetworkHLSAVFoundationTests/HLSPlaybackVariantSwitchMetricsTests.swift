#if canImport(AVFoundation)
import AVFoundation
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS variant-switch metrics")
struct HLSPlaybackVariantSwitchMetricsTests {
    @Test("variant bitrates retain only finite positive values")
    func variantBitratesAreNormalized() {
        let metric = HLSPlaybackVariantBitrateMetric(
            peak: .infinity,
            average: -1
        )
        let valid = HLSPlaybackVariantBitrateMetric(
            peak: 5_000_000,
            average: 3_000_000
        )

        #expect(metric.peak == nil)
        #expect(metric.average == nil)
        #expect(valid.peak == 5_000_000)
        #expect(valid.average == 3_000_000)
    }

    @Test("rendition identities preserve only bounded HLS stable IDs")
    func renditionIdentitiesAreValidated() {
        let valid = HLSPlaybackRenditionSelectionMetric(
            videoStableID: "video.main-1",
            audioStableID: "audio_main/2=",
            subtitleStableID: nil
        )
        let invalid = HLSPlaybackRenditionSelectionMetric(
            videoStableID: "video main",
            audioStableID: String(
                repeating: "a",
                count:
                    HLSPlaybackRenditionSelectionMetric
                    .maximumStableIDUTF8ByteCount + 1
            ),
            subtitleStableID: "자막"
        )

        #expect(valid.videoStableID == "video.main-1")
        #expect(valid.audioStableID == "audio_main/2=")
        #expect(valid.subtitleStableID == nil)
        #expect(valid.didRedactStableIDs == false)
        #expect(invalid.videoStableID == nil)
        #expect(invalid.audioStableID == nil)
        #expect(invalid.subtitleStableID == nil)
        #expect(invalid.didRedactStableIDs)
    }

    @Test("missing rendition identities are not classified as redaction")
    func missingRenditionIdentitiesRemainDistinct() {
        let selection = HLSPlaybackRenditionSelectionMetric(
            videoStableID: nil,
            audioStableID: nil,
            subtitleStableID: nil
        )

        #expect(selection.videoStableID == nil)
        #expect(selection.audioStableID == nil)
        #expect(selection.subtitleStableID == nil)
        #expect(selection.didRedactStableIDs == false)
    }

    @Test("invalid rendition identities do not hide valid siblings")
    func invalidRenditionIdentitiesDoNotHideValidSiblings() {
        let selection = HLSPlaybackRenditionSelectionMetric(
            videoStableID: "invalid video",
            audioStableID: "audio.main",
            subtitleStableID: String(
                repeating: "s",
                count:
                    HLSPlaybackRenditionSelectionMetric
                    .maximumStableIDUTF8ByteCount
            )
        )

        #expect(selection.videoStableID == nil)
        #expect(selection.audioStableID == "audio.main")
        #expect(
            selection.subtitleStableID
                == String(
                    repeating: "s",
                    count:
                        HLSPlaybackRenditionSelectionMetric
                        .maximumStableIDUTF8ByteCount
                )
        )
        #expect(selection.didRedactStableIDs)
    }
}
#endif
