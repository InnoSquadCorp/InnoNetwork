#if canImport(AVFoundation)
import AVFoundation
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS playback-readiness metrics")
struct HLSPlaybackReadinessMetricsTests {
    @Test("readiness details preserve their bounded event shape")
    func readinessDetailsArePreserved() {
        let context = HLSPlaybackMetricContext(
            date: Date(timeIntervalSince1970: 1_000),
            mediaTime: 12
        )
        let variant = HLSPlaybackVariantBitrateMetric(
            peak: 5_000_000,
            average: 3_000_000
        )
        let buffer = HLSPlaybackBufferMetric([
            CMTimeRange(
                start: CMTime(seconds: 12, preferredTimescale: 600),
                duration: CMTime(seconds: 4, preferredTimescale: 600)
            )
        ])
        let metric = HLSPlaybackReadinessMetric(
            context: context,
            isInitial: false,
            timeTaken: 1.5,
            variant: variant,
            buffer: buffer
        )

        #expect(metric.context == context)
        #expect(metric.isInitial == false)
        #expect(metric.timeTaken == 1.5)
        #expect(metric.variant == variant)
        #expect(metric.buffer == buffer)
    }

    @Test("readiness details omit unsafe durations")
    func readinessDurationsAreNormalized() {
        let context = HLSPlaybackMetricContext(
            date: Date(timeIntervalSince1970: 1_000),
            mediaTime: nil
        )
        let emptyBuffer = HLSPlaybackBufferMetric([])

        for duration in [Double.nan, .infinity, -.infinity, -1] {
            let metric = HLSPlaybackReadinessMetric(
                context: context,
                isInitial: true,
                timeTaken: duration,
                variant: nil,
                buffer: emptyBuffer
            )
            #expect(metric.timeTaken == nil)
        }
    }
}
#endif
