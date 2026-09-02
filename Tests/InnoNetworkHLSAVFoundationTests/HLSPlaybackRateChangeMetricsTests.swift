#if canImport(AVFoundation)
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS playback-rate change metrics")
struct HLSPlaybackRateChangeMetricsTests {
    @Test("rate-change details preserve reason, variant, and reverse rate")
    func rateChangeDetailsArePreserved() {
        let context = HLSPlaybackMetricContext(
            date: Date(timeIntervalSince1970: 1_000),
            mediaTime: 12
        )
        let variant = HLSPlaybackVariantBitrateMetric(
            peak: 5_000_000,
            average: 3_000_000
        )
        let metric = HLSPlaybackRateChangeMetric(
            context: context,
            reason: .seekCompleted(didSeekInBuffer: true),
            previousRate: 1,
            rate: -2,
            variant: variant
        )

        #expect(metric.context == context)
        #expect(metric.reason == .seekCompleted(didSeekInBuffer: true))
        #expect(metric.previousRate == 1)
        #expect(metric.rate == -2)
        #expect(metric.variant == variant)
    }

    @Test("rate-change details omit non-finite rates")
    func rateChangeRatesAreNormalized() {
        let metric = HLSPlaybackRateChangeMetric(
            context: HLSPlaybackMetricContext(
                date: Date(timeIntervalSince1970: 1_000),
                mediaTime: nil
            ),
            reason: .stalled,
            previousRate: .nan,
            rate: .infinity,
            variant: nil
        )

        #expect(metric.previousRate == nil)
        #expect(metric.rate == nil)
        #expect(metric.reason == .stalled)
    }
}
#endif
