#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation
import Foundation

/// URL-free media attributes for one variant retained by an AVFoundation HLS
/// download.
public struct HLSAssetDownloadVariantSummary: Equatable, Sendable {
    /// Peak bitrate in bits per second, when finite and positive.
    public let peakBitRate: Double?

    /// Average bitrate in bits per second, when finite and positive.
    public let averageBitRate: Double?

    /// Whether AVFoundation reported video attributes for the variant.
    public let hasVideo: Bool

    /// Whether AVFoundation reported audio attributes for the variant.
    public let hasAudio: Bool

    init(
        peakBitRate: Double?,
        averageBitRate: Double?,
        hasVideo: Bool,
        hasAudio: Bool
    ) {
        self.peakBitRate = Self.finitePositive(peakBitRate)
        self.averageBitRate = Self.finitePositive(averageBitRate)
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
    }

    private static func finitePositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else {
            return nil
        }
        return value
    }
}

/// Bounded, URL-free variants selected for one AVFoundation HLS download.
public struct HLSAssetDownloadVariantSelection: Equatable, Sendable {
    static let maximumRetainedVariantCount = 64

    /// Total variants selected before bounded retention.
    public let variantCount: Int

    /// Details for at most 64 selected variants.
    public let variants: [HLSAssetDownloadVariantSummary]

    /// Whether selected-variant details exceeded the retention bound.
    public let didTruncateVariants: Bool

    init(
        variants: [HLSAssetDownloadVariantSummary],
        variantCount: Int? = nil
    ) {
        self.variantCount = max(
            variants.count,
            variantCount ?? variants.count
        )
        self.variants = Array(
            variants.prefix(Self.maximumRetainedVariantCount)
        )
        self.didTruncateVariants = self.variantCount > self.variants.count
    }

    init(_ selectedVariants: [AVAssetVariant]) {
        self.init(
            variants:
                selectedVariants
                .prefix(Self.maximumRetainedVariantCount)
                .map { variant in
                    HLSAssetDownloadVariantSummary(
                        peakBitRate: variant.peakBitRate,
                        averageBitRate: variant.averageBitRate,
                        hasVideo: variant.videoAttributes != nil,
                        hasAudio: variant.audioAttributes != nil
                    )
                },
            variantCount: selectedVariants.count
        )
    }
}

/// Bounded, value-redacted metrics for one system-managed HLS download.
public struct HLSAssetDownloadSummary: Equatable, Sendable {
    /// The wall-clock time when AVFoundation emitted the summary.
    public let date: Date

    /// Recoverable errors encountered during the download.
    ///
    /// Compare this count only between downloads on the same OS version;
    /// AVFoundation's error reporting may change across system updates.
    public let recoverableErrorCount: Int

    /// Playlist, segment, and content-key requests performed.
    public let mediaResourceRequestCount: Int

    /// Total bytes downloaded, normalized to a non-negative value.
    public let bytesDownloaded: Int64

    /// Download duration in seconds, when finite and non-negative.
    public let downloadDuration: TimeInterval?

    /// Total variants selected by AVFoundation before bounded retention.
    public let variantCount: Int

    /// URL-free details for at most 64 selected variants.
    public let variants: [HLSAssetDownloadVariantSummary]

    /// Whether selected-variant details exceeded the retention bound.
    public let didTruncateVariants: Bool

    /// Whether AVFoundation attached an error metric to the summary.
    public let hadError: Bool

    init(
        date: Date,
        recoverableErrorCount: Int,
        mediaResourceRequestCount: Int,
        bytesDownloaded: Int,
        downloadDuration: TimeInterval,
        variants: [HLSAssetDownloadVariantSummary],
        variantCount: Int? = nil,
        hadError: Bool
    ) {
        self.date = date
        self.recoverableErrorCount = max(0, recoverableErrorCount)
        self.mediaResourceRequestCount = max(
            0,
            mediaResourceRequestCount
        )
        self.bytesDownloaded = Int64(max(0, bytesDownloaded))
        self.downloadDuration =
            downloadDuration.isFinite && downloadDuration >= 0
            ? downloadDuration
            : nil
        let selection = HLSAssetDownloadVariantSelection(
            variants: variants,
            variantCount: variantCount
        )
        self.variantCount = selection.variantCount
        self.variants = selection.variants
        self.didTruncateVariants = selection.didTruncateVariants
        self.hadError = hadError
    }
}

/// Isolates the OS 26 download-summary metric from the package's lower
/// deployment targets.
@available(macOS 26, iOS 26, watchOS 26, visionOS 26, *)
enum HLSAssetDownloadMetricMapper {
    static func map(
        _ metric: AVMetricEvent
    ) -> HLSAssetDownloadSummary? {
        guard let event = metric as? AVMetricDownloadSummaryEvent else {
            return nil
        }
        let selectedVariants = event.variants
        let selection = HLSAssetDownloadVariantSelection(selectedVariants)
        return HLSAssetDownloadSummary(
            date: event.date,
            recoverableErrorCount: event.recoverableErrorCount,
            mediaResourceRequestCount:
                event.mediaResourceRequestCount,
            bytesDownloaded: event.bytesDownloadedCount,
            downloadDuration: event.downloadDuration,
            variants: selection.variants,
            variantCount: selection.variantCount,
            hadError: event.errorEvent != nil
        )
    }
}
#endif
