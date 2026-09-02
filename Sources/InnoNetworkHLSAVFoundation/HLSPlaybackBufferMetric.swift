import AVFoundation
import Foundation

/// A bounded, URL-free snapshot of readily available playback media.
public struct HLSPlaybackBufferMetric: Equatable, Sendable {
    static let maximumLoadedTimeRangeCount = 256

    /// The number of loaded ranges AVFoundation reported before filtering.
    public let reportedLoadedTimeRangeCount: Int

    /// Finite, nonnegative-duration loaded ranges in media-timeline seconds.
    ///
    /// At most 256 ranges are retained in AVFoundation order. Empty ranges
    /// remain represented with equal lower and upper bounds.
    public let loadedTimeRanges: [Range<TimeInterval>]

    /// Whether an invalid range or a range beyond the retention bound was
    /// omitted.
    public let didOmitLoadedTimeRanges: Bool

    init(_ loadedTimeRanges: [CMTimeRange]) {
        reportedLoadedTimeRangeCount = loadedTimeRanges.count
        self.loadedTimeRanges =
            loadedTimeRanges
            .prefix(Self.maximumLoadedTimeRangeCount)
            .compactMap(HLSTimeRangeMapper.range)
        didOmitLoadedTimeRanges =
            self.loadedTimeRanges.count != loadedTimeRanges.count
    }
}
