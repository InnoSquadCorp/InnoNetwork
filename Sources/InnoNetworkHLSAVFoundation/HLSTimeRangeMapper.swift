import AVFoundation
import Foundation

enum HLSTimeRangeMapper {
    static func range(
        _ value: CMTimeRange
    ) -> Range<TimeInterval>? {
        guard
            let start = finite(value.start),
            let duration = finiteNonnegative(value.duration)
        else {
            return nil
        }
        let end = start + duration
        guard end.isFinite, end >= start else {
            return nil
        }
        return start..<end
    }

    static func finite(_ time: CMTime) -> TimeInterval? {
        guard time.isNumeric, time.seconds.isFinite else {
            return nil
        }
        return time.seconds
    }

    static func finiteNonnegative(
        _ time: CMTime
    ) -> TimeInterval? {
        guard let seconds = finite(time), seconds >= 0 else {
            return nil
        }
        return seconds
    }
}
