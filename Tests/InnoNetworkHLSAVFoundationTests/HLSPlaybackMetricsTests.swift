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

    @Test("startup request retention is bounded and chronological")
    @available(macOS 15, iOS 18, watchOS 11, visionOS 2, *)
    func startupRequestRetentionIsBoundedAndChronological() {
        let base = Date(timeIntervalSince1970: 1_000)
        let later = HLSPlaybackMetricContext(
            date: base.addingTimeInterval(2),
            mediaTime: 2
        )
        let earlier = HLSPlaybackMetricContext(
            date: base.addingTimeInterval(1),
            mediaTime: 1
        )
        let sortedRequests =
            HLSPlaybackStartupMetricMapper
            .chronologicallySorted([
                .mediaSegmentRequest(
                    later,
                    mediaType: .video,
                    isMapSegment: false,
                    segmentDuration: 2,
                    transfer: nil
                ),
                .playlistRequest(
                    earlier,
                    mediaType: .video,
                    isMultivariant: true,
                    transfer: nil
                ),
                .mediaSegmentRequest(
                    later,
                    mediaType: .audio,
                    isMapSegment: false,
                    segmentDuration: 2,
                    transfer: nil
                ),
            ])
        let metric = HLSPlaybackStartupMetric(
            readiness: HLSPlaybackReadinessMetric(
                context: later,
                isInitial: true,
                timeTaken: 2,
                variant: nil,
                buffer: HLSPlaybackBufferMetric([])
            ),
            playlistRequestCount: 1,
            mediaSegmentRequestCount: 2,
            contentKeyRequestCount: 0,
            requests: sortedRequests,
            maximumRetainedRequestCount: 2
        )

        #expect(metric.requestCount == 3)
        #expect(metric.requests.count == 2)
        #expect(metric.didTruncateRequests)
        guard
            case .playlistRequest(let first, _, _, _) = metric.requests[0]
        else {
            Issue.record("Expected the earlier playlist request first.")
            return
        }
        guard
            case .mediaSegmentRequest(let second, _, _, _, _) =
                metric.requests[1]
        else {
            Issue.record("Expected a later media-segment request second.")
            return
        }
        #expect(first == earlier)
        #expect(second == later)
    }

    @Test("startup metrics normalize limits and invalid time")
    @available(macOS 15, iOS 18, watchOS 11, visionOS 2, *)
    func startupMetricsNormalizeLimitsAndInvalidTime() {
        let context = HLSPlaybackMetricContext(
            date: Date(timeIntervalSince1970: 1_000),
            mediaTime: nil
        )
        let metric = HLSPlaybackStartupMetric(
            readiness: HLSPlaybackReadinessMetric(
                context: context,
                isInitial: true,
                timeTaken: .nan,
                variant: nil,
                buffer: HLSPlaybackBufferMetric([])
            ),
            playlistRequestCount: -1,
            mediaSegmentRequestCount: 0,
            contentKeyRequestCount: 0,
            requests: [],
            maximumRetainedRequestCount: 0
        )

        #expect(metric.timeTaken == nil)
        #expect(metric.requestCount == 0)
        #expect(metric.didTruncateRequests == false)
        #expect(
            HLSPlaybackStartupMetric.clampedRetainedRequestCount(0) == 1
        )
        #expect(
            HLSPlaybackStartupMetric.clampedRetainedRequestCount(2_048)
                == 1_024
        )
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
