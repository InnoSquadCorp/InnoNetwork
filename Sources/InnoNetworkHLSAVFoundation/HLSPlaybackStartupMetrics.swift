import AVFoundation
import Foundation

/// Bounded, URL-free diagnostics for initial HLS startup.
public struct HLSPlaybackStartupMetric: Equatable, Sendable {
    static let maximumRetainedRequestCount = 1_024

    /// Metadata for the initial likely-to-keep-up event.
    public let context: HLSPlaybackMetricContext

    /// Time AVFoundation needed to become likely to keep up, when finite and
    /// nonnegative.
    public let timeTaken: TimeInterval?

    /// Bitrates for the selected startup variant, when supplied.
    public let variant: HLSPlaybackVariantBitrateMetric?

    /// Readily available media when startup became likely to keep up.
    public let buffer: HLSPlaybackBufferMetric

    /// Playlist requests before bounded detail retention.
    public let playlistRequestCount: Int

    /// Media-segment requests before bounded detail retention.
    public let mediaSegmentRequestCount: Int

    /// Content-key requests before bounded detail retention.
    public let contentKeyRequestCount: Int

    /// All startup requests reported by AVFoundation.
    public var requestCount: Int {
        playlistRequestCount
            + mediaSegmentRequestCount
            + contentKeyRequestCount
    }

    /// Chronological URL-free request events retained for diagnosis.
    ///
    /// Every element is a playlist, media-segment, or content-key request case
    /// from ``HLSPlaybackMetricEvent``.
    public let requests: [HLSPlaybackMetricEvent]

    /// Whether request details exceeded the configured retention bound.
    public let didTruncateRequests: Bool

    init(
        readiness: HLSPlaybackReadinessMetric,
        playlistRequestCount: Int,
        mediaSegmentRequestCount: Int,
        contentKeyRequestCount: Int,
        requests: [HLSPlaybackMetricEvent],
        maximumRetainedRequestCount: Int
    ) {
        context = readiness.context
        timeTaken = readiness.timeTaken
        variant = readiness.variant
        buffer = readiness.buffer
        self.playlistRequestCount = max(0, playlistRequestCount)
        self.mediaSegmentRequestCount = max(
            0,
            mediaSegmentRequestCount
        )
        self.contentKeyRequestCount = max(0, contentKeyRequestCount)
        let limit = Self.clampedRetainedRequestCount(
            maximumRetainedRequestCount
        )
        self.requests = Array(requests.prefix(limit))
        didTruncateRequests =
            self.playlistRequestCount
            + self.mediaSegmentRequestCount
            + self.contentKeyRequestCount
            > self.requests.count
    }

    static func clampedRetainedRequestCount(_ value: Int) -> Int {
        min(maximumRetainedRequestCount, max(1, value))
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
extension HLSPlaybackMetrics {
    /// Starts an independently cancellable stream of initial-startup metrics.
    ///
    /// AVFoundation correlates these request events with the first point at
    /// which playback became likely to keep up. Request details exclude URLs,
    /// server addresses, headers, session identifiers, task metrics, and
    /// arbitrary error values. The retention limit is clamped to `1...1,024`.
    ///
    /// This method creates its own AVFoundation subscription. Prefer this
    /// stream over ``events()`` when startup-request correlation is required;
    /// consuming both streams observes the same native session independently.
    public func startupEvents(
        maximumRetainedRequestCount: Int = 128
    ) -> AsyncThrowingStream<HLSPlaybackStartupMetric, Error> {
        let requestLimit =
            HLSPlaybackStartupMetric
            .clampedRetainedRequestCount(
                maximumRetainedRequestCount
            )
        return makeEventStream { metric in
            HLSPlaybackStartupMetricMapper.map(
                metric,
                maximumRetainedRequestCount: requestLimit
            )
        }
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
enum HLSPlaybackStartupMetricMapper {
    static func map(
        _ metric: AVMetricEvent,
        maximumRetainedRequestCount: Int
    ) -> HLSPlaybackStartupMetric? {
        guard
            let event =
                metric as? AVMetricPlayerItemInitialLikelyToKeepUpEvent
        else {
            return nil
        }

        let playlistRequests = event.playlistRequestEvents.map(
            HLSPlaybackMetricMapper.map
        )
        let mediaSegmentRequests =
            event.mediaSegmentRequestEvents.map(
                HLSPlaybackMetricMapper.map
            )
        let contentKeyRequests =
            event.contentKeyRequestEvents.map(
                HLSPlaybackMetricMapper.map
            )
        let requests = chronologicallySorted(
            playlistRequests
                + mediaSegmentRequests
                + contentKeyRequests
        )

        return HLSPlaybackStartupMetric(
            readiness: HLSPlaybackReadinessMetricMapper.map(
                event,
                isInitial: true
            ),
            playlistRequestCount: playlistRequests.count,
            mediaSegmentRequestCount: mediaSegmentRequests.count,
            contentKeyRequestCount: contentKeyRequests.count,
            requests: requests,
            maximumRetainedRequestCount: maximumRetainedRequestCount
        )
    }

    static func chronologicallySorted(
        _ requests: [HLSPlaybackMetricEvent]
    ) -> [HLSPlaybackMetricEvent] {
        requests.enumerated().sorted { lhs, rhs in
            let lhsDate = context(of: lhs.element).date
            let rhsDate = context(of: rhs.element).date
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func context(
        of event: HLSPlaybackMetricEvent
    ) -> HLSPlaybackMetricContext {
        switch event {
        case .playlistRequest(let context, _, _, _),
            .mediaSegmentRequest(let context, _, _, _, _),
            .contentKeyRequest(let context, _, _, _):
            return context
        default:
            preconditionFailure(
                "Startup request mapping produced a non-request event."
            )
        }
    }
}
