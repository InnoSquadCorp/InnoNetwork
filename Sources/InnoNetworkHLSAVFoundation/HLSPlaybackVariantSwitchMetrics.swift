import AVFoundation
import Foundation
import InnoNetworkHLS

/// URL-free bitrate attributes for one HLS playback variant.
public struct HLSPlaybackVariantBitrateMetric: Equatable, Sendable {
    /// Peak bitrate in bits per second, when finite and positive.
    public let peak: Double?

    /// Average bitrate in bits per second, when finite and positive.
    public let average: Double?

    init(peak: Double?, average: Double?) {
        self.peak = Self.finitePositive(peak)
        self.average = Self.finitePositive(average)
    }

    init(_ variant: AVAssetVariant) {
        self.init(
            peak: variant.peakBitRate,
            average: variant.averageBitRate
        )
    }

    private static func finitePositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else {
            return nil
        }
        return value
    }
}

/// URL-free rendition identities associated with one HLS variant switch.
public struct HLSPlaybackRenditionSelectionMetric: Equatable, Sendable {
    static let maximumStableIDUTF8ByteCount = 1_024

    /// The selected video's authored `STABLE-RENDITION-ID`, when safe.
    public let videoStableID: String?

    /// The selected audio's authored `STABLE-RENDITION-ID`, when safe.
    public let audioStableID: String?

    /// The selected subtitle's authored `STABLE-RENDITION-ID`, when safe.
    public let subtitleStableID: String?

    /// Whether an invalid or oversized stable ID was omitted.
    public let didRedactStableIDs: Bool

    init(
        videoStableID: String?,
        audioStableID: String?,
        subtitleStableID: String?
    ) {
        let video = Self.safeStableID(videoStableID)
        let audio = Self.safeStableID(audioStableID)
        let subtitle = Self.safeStableID(subtitleStableID)
        self.videoStableID = video.value
        self.audioStableID = audio.value
        self.subtitleStableID = subtitle.value
        didRedactStableIDs =
            video.didRedact || audio.didRedact || subtitle.didRedact
    }

    private static func safeStableID(
        _ value: String?
    ) -> (value: String?, didRedact: Bool) {
        guard let value else {
            return (nil, false)
        }
        guard
            value.utf8.count <= maximumStableIDUTF8ByteCount,
            HLSStableIdentifierValidator.isValid(value)
        else {
            return (nil, true)
        }
        return (value, false)
    }
}

/// A URL-free, detailed HLS variant-switch metric.
public struct HLSPlaybackVariantSwitchMetric: Equatable, Sendable {
    /// Metadata for the native variant-switch event.
    public let context: HLSPlaybackMetricContext

    /// Whether the switch started or completed.
    public let phase: HLSPlaybackVariantSwitchPhase

    /// Bitrates for the source variant, when AVFoundation supplied one.
    public let fromVariant: HLSPlaybackVariantBitrateMetric?

    /// Bitrates for the requested or selected destination variant.
    public let toVariant: HLSPlaybackVariantBitrateMetric

    /// Readily available media at the variant-switch boundary.
    public let buffer: HLSPlaybackBufferMetric

    /// Selected rendition identities on version 26 and later systems.
    ///
    /// A `nil` value means the operating system did not provide rendition
    /// metrics. Missing authored stable IDs remain `nil` inside a non-`nil`
    /// selection.
    public let renditions: HLSPlaybackRenditionSelectionMetric?
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
extension HLSPlaybackMetrics {
    /// Starts an independently cancellable detailed variant-switch stream.
    ///
    /// The stream excludes variant and rendition playlist URLs. Version 26
    /// systems add authored stable rendition IDs after validating their HLS
    /// grammar and bounding each value to 1,024 UTF-8 bytes. Earlier systems
    /// emit the same switch metrics with `nil` rendition details.
    public func variantSwitchEvents()
        -> AsyncThrowingStream<HLSPlaybackVariantSwitchMetric, Error>
    {
        makeEventStream { metric in
            HLSPlaybackVariantSwitchMetricMapper.map(metric)
        }
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
enum HLSPlaybackVariantSwitchMetricMapper {
    static func map(
        _ metric: AVMetricEvent
    ) -> HLSPlaybackVariantSwitchMetric? {
        let context = HLSPlaybackMetricMapper.context(metric)
        switch metric {
        case let event as AVMetricPlayerItemVariantSwitchStartEvent:
            return HLSPlaybackVariantSwitchMetric(
                context: context,
                phase: .started,
                fromVariant: event.fromVariant.map(
                    HLSPlaybackVariantBitrateMetric.init
                ),
                toVariant: HLSPlaybackVariantBitrateMetric(
                    event.toVariant
                ),
                buffer: HLSPlaybackBufferMetric(event.loadedTimeRanges),
                renditions: renditionSelection(event)
            )
        case let event as AVMetricPlayerItemVariantSwitchEvent:
            return HLSPlaybackVariantSwitchMetric(
                context: context,
                phase: .completed(didSucceed: event.didSucceed),
                fromVariant: event.fromVariant.map(
                    HLSPlaybackVariantBitrateMetric.init
                ),
                toVariant: HLSPlaybackVariantBitrateMetric(
                    event.toVariant
                ),
                buffer: HLSPlaybackBufferMetric(event.loadedTimeRanges),
                renditions: renditionSelection(event)
            )
        default:
            return nil
        }
    }

    private static func renditionSelection(
        _ event: AVMetricPlayerItemVariantSwitchStartEvent
    ) -> HLSPlaybackRenditionSelectionMetric? {
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            return HLSPlaybackRenditionSelectionMetric(
                videoStableID: event.videoRendition.stableID,
                audioStableID: event.audioRendition.stableID,
                subtitleStableID: event.subtitleRendition.stableID
            )
        }
        return nil
    }

    private static func renditionSelection(
        _ event: AVMetricPlayerItemVariantSwitchEvent
    ) -> HLSPlaybackRenditionSelectionMetric? {
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            return HLSPlaybackRenditionSelectionMetric(
                videoStableID: event.videoRendition.stableID,
                audioStableID: event.audioRendition.stableID,
                subtitleStableID: event.subtitleRendition.stableID
            )
        }
        return nil
    }
}
