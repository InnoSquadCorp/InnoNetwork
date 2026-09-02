#if canImport(AVFoundation)
import AVFoundation
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS playback-buffer metrics")
struct HLSPlaybackBufferMetricTests {
    @Test("loaded ranges retain valid values and report invalid omission")
    func loadedRangesAreValidated() {
        let metric = HLSPlaybackBufferMetric([
            CMTimeRange(
                start: CMTime(seconds: 2, preferredTimescale: 600),
                duration: CMTime(seconds: 3, preferredTimescale: 600)
            ),
            CMTimeRange(start: .zero, duration: .zero),
            CMTimeRange(start: .invalid, duration: .zero),
            CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: -1, preferredTimescale: 600)
            ),
        ])

        #expect(metric.reportedLoadedTimeRangeCount == 4)
        #expect(metric.loadedTimeRanges == [2..<5, 0..<0])
        #expect(metric.didOmitLoadedTimeRanges)
    }

    @Test("loaded ranges retain at most the bounded prefix")
    func loadedRangesAreBounded() {
        let ranges = (0...HLSPlaybackBufferMetric.maximumLoadedTimeRangeCount)
            .map { offset in
                CMTimeRange(
                    start: CMTime(
                        seconds: Double(offset),
                        preferredTimescale: 600
                    ),
                    duration: CMTime(seconds: 1, preferredTimescale: 600)
                )
            }
        let metric = HLSPlaybackBufferMetric(ranges)
        let exact = HLSPlaybackBufferMetric(Array(ranges.dropLast()))

        #expect(
            metric.reportedLoadedTimeRangeCount
                == HLSPlaybackBufferMetric.maximumLoadedTimeRangeCount + 1
        )
        #expect(
            metric.loadedTimeRanges.count
                == HLSPlaybackBufferMetric.maximumLoadedTimeRangeCount
        )
        #expect(metric.loadedTimeRanges.last == 255..<256)
        #expect(metric.didOmitLoadedTimeRanges)
        #expect(
            exact.loadedTimeRanges.count
                == HLSPlaybackBufferMetric.maximumLoadedTimeRangeCount
        )
        #expect(exact.didOmitLoadedTimeRanges == false)
    }

    @Test("empty loaded ranges do not report omission")
    func emptyLoadedRangesAreComplete() {
        let metric = HLSPlaybackBufferMetric([])

        #expect(metric.reportedLoadedTimeRangeCount == 0)
        #expect(metric.loadedTimeRanges.isEmpty)
        #expect(metric.didOmitLoadedTimeRanges == false)
    }

    @Test("startup and variant-switch details share one buffer contract")
    func detailedMetricsShareBufferContract() {
        let context = HLSPlaybackMetricContext(
            date: Date(timeIntervalSince1970: 1_000),
            mediaTime: 2
        )
        let buffer = HLSPlaybackBufferMetric([
            CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: 4, preferredTimescale: 600)
            )
        ])
        let variant = HLSPlaybackVariantBitrateMetric(
            peak: 5_000_000,
            average: 3_000_000
        )
        let startup = HLSPlaybackStartupMetric(
            context: context,
            timeTaken: 2,
            variant: variant,
            buffer: buffer,
            playlistRequestCount: 0,
            mediaSegmentRequestCount: 0,
            contentKeyRequestCount: 0,
            requests: [],
            maximumRetainedRequestCount: 1
        )
        let variantSwitch = HLSPlaybackVariantSwitchMetric(
            context: context,
            phase: .started,
            fromVariant: nil,
            toVariant: variant,
            buffer: buffer,
            renditions: nil
        )

        #expect(startup.variant == variant)
        #expect(startup.buffer == buffer)
        #expect(variantSwitch.buffer == buffer)
    }
}
#endif
