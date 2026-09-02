import AVFoundation
import Foundation

/// The cause represented by one AVFoundation playback-rate change event.
public enum HLSPlaybackRateChangeReason: Equatable, Sendable {
    /// The application or player changed rate without a more specific cause.
    case rateChanged

    /// Playback stalled.
    case stalled

    /// A seek started.
    case seekStarted

    /// A seek completed.
    case seekCompleted(didSeekInBuffer: Bool)
}

/// URL-free details for one playback rate, stall, or seek transition.
public struct HLSPlaybackRateChangeMetric: Equatable, Sendable {
    /// Metadata for the native rate-change event.
    public let context: HLSPlaybackMetricContext

    /// The rate-change cause and any cause-specific result.
    public let reason: HLSPlaybackRateChangeReason

    /// Playback rate before the transition, when finite.
    public let previousRate: Double?

    /// Playback rate after the transition, when finite.
    public let rate: Double?

    /// Bitrates for the selected variant, when supplied.
    public let variant: HLSPlaybackVariantBitrateMetric?

    init(
        context: HLSPlaybackMetricContext,
        reason: HLSPlaybackRateChangeReason,
        previousRate: Double,
        rate: Double,
        variant: HLSPlaybackVariantBitrateMetric?
    ) {
        self.context = context
        self.reason = reason
        self.previousRate = Self.finite(previousRate)
        self.rate = Self.finite(rate)
        self.variant = variant
    }

    private static func finite(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
extension HLSPlaybackMetrics {
    /// Starts an independently cancellable detailed rate-change stream.
    ///
    /// AVFoundation represents ordinary rate changes, stalls, seek starts,
    /// and seek completions through one event hierarchy. This stream preserves
    /// that cause together with finite rates and URL-free variant bitrates.
    public func rateChangeEvents()
        -> AsyncThrowingStream<HLSPlaybackRateChangeMetric, Error>
    {
        makeEventStream { metric in
            HLSPlaybackRateChangeMetricMapper.map(metric)
        }
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
enum HLSPlaybackRateChangeMetricMapper {
    static func map(
        _ metric: AVMetricEvent
    ) -> HLSPlaybackRateChangeMetric? {
        guard let event = metric as? AVMetricPlayerItemRateChangeEvent else {
            return nil
        }
        return HLSPlaybackRateChangeMetric(
            context: HLSPlaybackMetricMapper.context(event),
            reason: reason(event),
            previousRate: event.previousRate,
            rate: event.rate,
            variant: event.variant.map(HLSPlaybackVariantBitrateMetric.init)
        )
    }

    private static func reason(
        _ event: AVMetricPlayerItemRateChangeEvent
    ) -> HLSPlaybackRateChangeReason {
        switch event {
        case let event as AVMetricPlayerItemSeekDidCompleteEvent:
            return .seekCompleted(
                didSeekInBuffer: event.didSeekInBuffer
            )
        case _ as AVMetricPlayerItemSeekEvent:
            return .seekStarted
        case _ as AVMetricPlayerItemStallEvent:
            return .stalled
        default:
            return .rateChanged
        }
    }
}
