import AVFoundation
import Foundation

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
