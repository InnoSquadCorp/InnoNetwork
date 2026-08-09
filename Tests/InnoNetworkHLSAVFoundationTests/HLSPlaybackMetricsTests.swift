#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS playback metrics")
struct HLSPlaybackMetricsTests {
    @Test("buffer limits are clamped to a bounded range")
    @available(macOS 15, iOS 18, watchOS 11, visionOS 2, *)
    func bufferLimitsAreBounded() {
        #expect(
            HLSPlaybackMetrics.clampedBufferedEventCount(-1) == 1
        )
        #expect(
            HLSPlaybackMetrics.clampedBufferedEventCount(64) == 64
        )
        #expect(
            HLSPlaybackMetrics.clampedBufferedEventCount(2_048) == 1_024
        )
    }

    @Test("non-finite playback rates are removed")
    @available(macOS 15, iOS 18, watchOS 11, visionOS 2, *)
    func nonFiniteRatesAreRemoved() {
        #expect(HLSPlaybackMetricMapper.finite(-2) == -2)
        #expect(HLSPlaybackMetricMapper.finite(.nan) == nil)
        #expect(HLSPlaybackMetricMapper.finite(.infinity) == nil)
        #expect(HLSPlaybackMetricMapper.finite(-.infinity) == nil)
    }

    @Test("observation errors expose no underlying values")
    func observationErrorsAreRedacted() {
        let error = HLSPlaybackMetricsError.observationFailed

        #expect(
            error.errorDescription
                == "AVFoundation playback metric observation failed."
        )
        #expect(
            error.recoverySuggestion
                == "Restart metric observation with a new event stream."
        )
        #expect(String(describing: error) == "observationFailed")
    }
}
#endif
