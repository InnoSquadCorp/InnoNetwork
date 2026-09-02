import AVFoundation
import Foundation

/// URL-free details for one point when playback became likely to keep up.
public struct HLSPlaybackReadinessMetric: Equatable, Sendable {
    /// Metadata for the native likely-to-keep-up event.
    public let context: HLSPlaybackMetricContext

    /// Whether this was the first likely-to-keep-up event for the item.
    public let isInitial: Bool

    /// Time AVFoundation needed to become likely to keep up, when finite and
    /// nonnegative.
    public let timeTaken: TimeInterval?

    /// Bitrates for the selected variant, when supplied.
    public let variant: HLSPlaybackVariantBitrateMetric?

    /// Readily available media when playback became likely to keep up.
    public let buffer: HLSPlaybackBufferMetric

    init(
        context: HLSPlaybackMetricContext,
        isInitial: Bool,
        timeTaken: TimeInterval,
        variant: HLSPlaybackVariantBitrateMetric?,
        buffer: HLSPlaybackBufferMetric
    ) {
        self.context = context
        self.isInitial = isInitial
        self.timeTaken =
            timeTaken.isFinite && timeTaken >= 0
            ? timeTaken
            : nil
        self.variant = variant
        self.buffer = buffer
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
extension HLSPlaybackMetrics {
    /// Starts an independently cancellable readiness-detail stream.
    ///
    /// The stream includes both the initial and subsequent points when
    /// AVFoundation reports that playback is likely to keep up. It excludes
    /// variant playlist URLs and bounds loaded time ranges through
    /// ``HLSPlaybackBufferMetric``.
    public func readinessEvents()
        -> AsyncThrowingStream<HLSPlaybackReadinessMetric, Error>
    {
        makeEventStream { metric in
            HLSPlaybackReadinessMetricMapper.map(metric)
        }
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
enum HLSPlaybackReadinessMetricMapper {
    static func map(
        _ metric: AVMetricEvent
    ) -> HLSPlaybackReadinessMetric? {
        guard
            let event = metric as? AVMetricPlayerItemLikelyToKeepUpEvent
        else {
            return nil
        }
        return map(
            event,
            isInitial:
                event is AVMetricPlayerItemInitialLikelyToKeepUpEvent
        )
    }

    static func map(
        _ event: AVMetricPlayerItemLikelyToKeepUpEvent,
        isInitial: Bool
    ) -> HLSPlaybackReadinessMetric {
        return HLSPlaybackReadinessMetric(
            context: HLSPlaybackMetricMapper.context(event),
            isInitial: isInitial,
            timeTaken: event.timeTaken,
            variant: event.variant.map(HLSPlaybackVariantBitrateMetric.init),
            buffer: HLSPlaybackBufferMetric(event.loadedTimeRanges)
        )
    }
}
