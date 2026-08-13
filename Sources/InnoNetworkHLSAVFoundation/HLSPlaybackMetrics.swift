import AVFoundation
import Foundation

/// Redacted common metadata for one AVFoundation playback metric.
public struct HLSPlaybackMetricContext: Equatable, Sendable {
    /// The wall-clock time when AVFoundation emitted the event.
    public let date: Date

    /// The media-timeline position in seconds, when numeric and finite.
    public let mediaTime: TimeInterval?
}

/// A redacted HLS media-type classification.
public enum HLSPlaybackMetricMediaType: Equatable, Sendable {
    /// Audio media.
    case audio

    /// Video media.
    case video

    /// Subtitle or text media.
    case subtitles

    /// Closed-caption media.
    case closedCaptions

    /// Timed metadata.
    case metadata

    /// Multiplexed media.
    case muxed

    /// A media type not modeled by this bridge.
    case other
}

/// Value-redacted timing for one AVFoundation media request.
public struct HLSPlaybackTransferMetric: Equatable, Sendable {
    /// Request start-to-end duration, when finite.
    public let requestDuration: TimeInterval?

    /// Response start-to-end duration, when finite.
    public let responseDuration: TimeInterval?

    /// The declared byte-range length, when available.
    public let byteCount: Int?

    /// Whether AVFoundation satisfied the request from cache.
    public let wasReadFromCache: Bool

    /// Whether the request produced an error metric.
    public let hadError: Bool

    /// Whether AVFoundation recovered from that error.
    public let didRecover: Bool
}

/// Aggregated, value-redacted metrics for one playback session.
public struct HLSPlaybackMetricSummary: Equatable, Sendable {
    /// Recoverable errors encountered during playback.
    public let recoverableErrorCount: Int

    /// Playback stalls encountered.
    public let stallCount: Int

    /// Variant switches encountered.
    public let variantSwitchCount: Int

    /// Playback duration in seconds.
    public let playbackDuration: TimeInterval

    /// Playlist, segment, and key requests performed.
    public let mediaResourceRequestCount: Int

    /// Time spent recovering from stalls.
    public let stallRecoveryDuration: TimeInterval

    /// Initial startup duration.
    public let initialStartupDuration: TimeInterval

    /// Playtime-weighted average bitrate in bits per second.
    public let timeWeightedAverageBitrate: Int

    /// Playtime-weighted peak bitrate in bits per second.
    public let timeWeightedPeakBitrate: Int

    /// Whether the summary contains a terminal error.
    public let hadError: Bool
}

/// The phase of one AVFoundation variant-switch metric.
public enum HLSPlaybackVariantSwitchPhase: Equatable, Sendable {
    /// AVFoundation started a variant-switch attempt.
    case started

    /// AVFoundation completed a variant-switch attempt.
    case completed(didSucceed: Bool)
}

/// The route represented by an AVFoundation playback-mode metric.
public enum HLSPlaybackMode: Equatable, Sendable {
    /// Playback is local to the device.
    case local

    /// Playback is routed through AirPlay Video.
    case airPlayVideo

    /// A future playback mode not modeled by this bridge.
    case other
}

/// A value-redacted failure from AVFoundation metric observation.
public enum HLSPlaybackMetricsError: Error, Equatable, Sendable {
    /// AVFoundation ended metric observation with an error.
    ///
    /// The bridge intentionally does not retain the underlying error because
    /// it may contain request URLs or other transport details.
    case observationFailed
}

extension HLSPlaybackMetricsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .observationFailed:
            "AVFoundation playback metric observation failed."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .observationFailed:
            "Restart metric observation with a new event stream."
        }
    }
}

/// A typed AVFoundation metric that excludes URLs, server addresses, session
/// identifiers, headers, task metrics, and arbitrary error values.
public enum HLSPlaybackMetricEvent: Equatable, Sendable {
    /// An error occurred.
    case error(
        HLSPlaybackMetricContext,
        didRecover: Bool
    )

    /// A media resource request completed.
    case mediaResourceRequest(
        HLSPlaybackMetricContext,
        transfer: HLSPlaybackTransferMetric
    )

    /// An HLS playlist request completed.
    case playlistRequest(
        HLSPlaybackMetricContext,
        mediaType: HLSPlaybackMetricMediaType,
        isMultivariant: Bool,
        transfer: HLSPlaybackTransferMetric?
    )

    /// An HLS media-segment request completed.
    case mediaSegmentRequest(
        HLSPlaybackMetricContext,
        mediaType: HLSPlaybackMetricMediaType,
        isMapSegment: Bool,
        segmentDuration: TimeInterval?,
        transfer: HLSPlaybackTransferMetric?
    )

    /// An HLS content-key request completed.
    case contentKeyRequest(
        HLSPlaybackMetricContext,
        mediaType: HLSPlaybackMetricMediaType,
        isClientInitiated: Bool,
        transfer: HLSPlaybackTransferMetric?
    )

    /// Playback became likely to continue without stalling.
    case likelyToKeepUp(
        HLSPlaybackMetricContext,
        isInitial: Bool,
        timeTaken: TimeInterval?
    )

    /// Playback rate changed.
    case rateChanged(
        HLSPlaybackMetricContext,
        previousRate: Double?,
        rate: Double?
    )

    /// Playback stalled.
    case stalled(HLSPlaybackMetricContext)

    /// A seek started.
    case seekStarted(HLSPlaybackMetricContext)

    /// A seek completed.
    case seekCompleted(
        HLSPlaybackMetricContext,
        didSeekInBuffer: Bool
    )

    /// A variant switch started or completed.
    case variantSwitch(
        HLSPlaybackMetricContext,
        phase: HLSPlaybackVariantSwitchPhase
    )

    /// AVFoundation emitted its playback summary.
    case playbackSummary(
        HLSPlaybackMetricContext,
        summary: HLSPlaybackMetricSummary
    )

    /// Playback moved between local and external presentation.
    case playbackModeChanged(
        HLSPlaybackMetricContext,
        mode: HLSPlaybackMode
    )

    /// AVFoundation emitted a future metric type.
    case unclassified(HLSPlaybackMetricContext)
}

/// Bridges `AVPlayerItem` metrics into bounded, redacted HLS events.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
public struct HLSPlaybackMetrics: Sendable {
    private let playerItem: AVPlayerItem
    private let maximumBufferedEventCount: Int

    /// Creates a metrics bridge for one player item.
    ///
    /// The buffer limit is clamped to `1...1,024`. Each call to ``events()``
    /// creates an independent AVFoundation subscription. When a consumer
    /// falls behind, the stream retains the newest events and discards the
    /// oldest buffered events.
    public init(
        playerItem: AVPlayerItem,
        maximumBufferedEventCount: Int = 64
    ) {
        self.playerItem = playerItem
        self.maximumBufferedEventCount = Self.clampedBufferedEventCount(
            maximumBufferedEventCount
        )
    }

    static func clampedBufferedEventCount(_ value: Int) -> Int {
        min(1_024, max(1, value))
    }

    /// Starts an independently cancellable metric-event stream.
    ///
    /// Cancellation finishes normally. AVFoundation observation failures are
    /// surfaced as the value-redacted
    /// ``HLSPlaybackMetricsError/observationFailed`` error.
    public func events()
        -> AsyncThrowingStream<HLSPlaybackMetricEvent, Error>
    {
        let (stream, continuation) =
            AsyncThrowingStream<
                HLSPlaybackMetricEvent,
                Error
            >.makeStream(
                bufferingPolicy: .bufferingNewest(
                    maximumBufferedEventCount
                )
            )
        let playerItem = playerItem
        let task = Task {
            do {
                for try await metric in playerItem.allMetrics() {
                    continuation.yield(
                        HLSPlaybackMetricMapper.map(metric)
                    )
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(
                    throwing: HLSPlaybackMetricsError.observationFailed
                )
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
enum HLSPlaybackMetricMapper {
    static func map(
        _ metric: AVMetricEvent
    ) -> HLSPlaybackMetricEvent {
        let context = context(metric)
        switch metric {
        case let event as AVMetricErrorEvent:
            return .error(
                context,
                didRecover: event.didRecover
            )
        case let event as AVMetricHLSPlaylistRequestEvent:
            return .playlistRequest(
                context,
                mediaType: mediaType(event.mediaType),
                isMultivariant: event.isMultivariantPlaylist,
                transfer: event.mediaResourceRequestEvent.map(
                    transferMetric
                )
            )
        case let event as AVMetricHLSMediaSegmentRequestEvent:
            return .mediaSegmentRequest(
                context,
                mediaType: mediaType(event.mediaType),
                isMapSegment: event.isMapSegment,
                segmentDuration: finiteNonnegative(
                    event.segmentDuration
                ),
                transfer: event.mediaResourceRequestEvent.map(
                    transferMetric
                )
            )
        case let event as AVMetricContentKeyRequestEvent:
            return .contentKeyRequest(
                context,
                mediaType: mediaType(event.mediaType),
                isClientInitiated: event.isClientInitiated,
                transfer: event.mediaResourceRequestEvent.map(
                    transferMetric
                )
            )
        case let event as AVMetricMediaResourceRequestEvent:
            return .mediaResourceRequest(
                context,
                transfer: transferMetric(event)
            )
        case let event as AVMetricPlayerItemInitialLikelyToKeepUpEvent:
            return .likelyToKeepUp(
                context,
                isInitial: true,
                timeTaken: finiteNonnegative(event.timeTaken)
            )
        case let event as AVMetricPlayerItemLikelyToKeepUpEvent:
            return .likelyToKeepUp(
                context,
                isInitial: false,
                timeTaken: finiteNonnegative(event.timeTaken)
            )
        case _ as AVMetricPlayerItemStallEvent:
            return .stalled(context)
        case _ as AVMetricPlayerItemSeekEvent:
            return .seekStarted(context)
        case let event as AVMetricPlayerItemSeekDidCompleteEvent:
            return .seekCompleted(
                context,
                didSeekInBuffer: event.didSeekInBuffer
            )
        case let event as AVMetricPlayerItemRateChangeEvent:
            return .rateChanged(
                context,
                previousRate: finite(event.previousRate),
                rate: finite(event.rate)
            )
        case _ as AVMetricPlayerItemVariantSwitchStartEvent:
            return .variantSwitch(context, phase: .started)
        case let event as AVMetricPlayerItemVariantSwitchEvent:
            return .variantSwitch(
                context,
                phase: .completed(
                    didSucceed: event.didSucceed
                )
            )
        case let event as AVMetricPlayerItemPlaybackSummaryEvent:
            return .playbackSummary(
                context,
                summary: summary(event)
            )
        default:
            return HLSPlaybackModeMetricMapper.map(
                metric,
                context: context
            ) ?? .unclassified(context)
        }
    }

    private static func context(
        _ metric: AVMetricEvent
    ) -> HLSPlaybackMetricContext {
        let seconds = metric.mediaTime.seconds
        return HLSPlaybackMetricContext(
            date: metric.date,
            mediaTime:
                metric.mediaTime.isNumeric && seconds.isFinite
                ? seconds
                : nil
        )
    }

    private static func transferMetric(
        _ event: AVMetricMediaResourceRequestEvent
    ) -> HLSPlaybackTransferMetric {
        let error = event.errorEvent
        return HLSPlaybackTransferMetric(
            requestDuration: interval(
                from: event.requestStartTime,
                to: event.requestEndTime
            ),
            responseDuration: interval(
                from: event.responseStartTime,
                to: event.responseEndTime
            ),
            byteCount:
                event.byteRange.length > 0
                ? event.byteRange.length
                : nil,
            wasReadFromCache: event.wasReadFromCache,
            hadError: error != nil,
            didRecover: error?.didRecover ?? false
        )
    }

    private static func summary(
        _ event: AVMetricPlayerItemPlaybackSummaryEvent
    ) -> HLSPlaybackMetricSummary {
        HLSPlaybackMetricSummary(
            recoverableErrorCount: max(
                0,
                event.recoverableErrorCount
            ),
            stallCount: max(0, event.stallCount),
            variantSwitchCount: max(
                0,
                event.variantSwitchCount
            ),
            playbackDuration: TimeInterval(
                max(0, event.playbackDuration)
            ),
            mediaResourceRequestCount: max(
                0,
                event.mediaResourceRequestCount
            ),
            stallRecoveryDuration:
                finiteNonnegative(
                    event.timeSpentRecoveringFromStall
                ) ?? 0,
            initialStartupDuration:
                finiteNonnegative(
                    event.timeSpentInInitialStartup
                ) ?? 0,
            timeWeightedAverageBitrate: max(
                0,
                event.timeWeightedAverageBitrate
            ),
            timeWeightedPeakBitrate: max(
                0,
                event.timeWeightedPeakBitrate
            ),
            hadError: event.errorEvent != nil
        )
    }

    private static func mediaType(
        _ type: AVMediaType
    ) -> HLSPlaybackMetricMediaType {
        switch type {
        case .audio:
            return .audio
        case .video:
            return .video
        case .subtitle, .text:
            return .subtitles
        case .closedCaption:
            return .closedCaptions
        case .metadata:
            return .metadata
        case .muxed:
            return .muxed
        default:
            return .other
        }
    }

    private static func interval(
        from start: Date,
        to end: Date
    ) -> TimeInterval? {
        finiteNonnegative(end.timeIntervalSince(start))
    }

    private static func finiteNonnegative(
        _ value: TimeInterval
    ) -> TimeInterval? {
        guard value.isFinite, value >= 0 else {
            return nil
        }
        return value
    }

    static func finite(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }
}
