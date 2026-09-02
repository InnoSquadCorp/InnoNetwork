import AVFoundation
import Foundation

@available(
    macOS 15,
    iOS 18,
    tvOS 18,
    watchOS 11,
    visionOS 2,
    *
)
enum HLSIntegratedTimelineMapper {
    static let maximumSegmentCount = 1_024
    static let maximumLoadedTimeRangeCount = 256
    static let maximumIdentifierUTF8ByteCount = 1_024

    static func snapshot(
        _ nativeSnapshot: AVPlayerItemIntegratedTimelineSnapshot
    ) -> HLSIntegratedTimelineSnapshot {
        let nativeSegments = nativeSnapshot.segments
        let retainedNativeSegments = nativeSegments.prefix(
            maximumSegmentCount
        )
        let currentSegmentIndex = nativeSnapshot.currentSegment.flatMap {
            nativeSegments.firstIndex(of: $0)
        }.flatMap {
            $0 < maximumSegmentCount ? $0 : nil
        }
        return HLSIntegratedTimelineSnapshot(
            duration: HLSTimeRangeMapper.finiteNonnegative(
                nativeSnapshot.duration
            ),
            currentTime: HLSTimeRangeMapper.finite(
                nativeSnapshot.currentTime
            ),
            currentDate: nativeSnapshot.currentDate,
            currentSegmentIndex: currentSegmentIndex,
            segments: retainedNativeSegments.map(segment),
            didTruncateSegments:
                nativeSegments.count > maximumSegmentCount
        )
    }

    static func segment(
        _ nativeSegment: AVPlayerItemSegment
    ) -> HLSIntegratedTimelineSegmentSnapshot {
        let loadedTimeRanges = nativeSegment.loadedTimeRanges
        let identifier = boundedIdentifier(
            nativeSegment.interstitialEvent?.identifier
        )
        let retainedLoadedTimeRanges =
            loadedTimeRanges
            .prefix(maximumLoadedTimeRangeCount)
            .compactMap(HLSTimeRangeMapper.range)
        return HLSIntegratedTimelineSegmentSnapshot(
            kind: kind(nativeSegment.segmentType),
            sourceTimeRange: HLSTimeRangeMapper.range(
                nativeSegment.timeMapping.source
            ),
            timelineTimeRange: HLSTimeRangeMapper.range(
                nativeSegment.timeMapping.target
            ),
            loadedTimelineTimeRanges: retainedLoadedTimeRanges,
            didTruncateLoadedTimeRanges:
                loadedTimeRanges.count
                > maximumLoadedTimeRangeCount,
            startDate: nativeSegment.startDate,
            interstitialIdentifier: identifier.value,
            didTruncateInterstitialIdentifier:
                identifier.wasTruncated
        )
    }

    static func updateReason(
        _ notification: Notification
    ) -> HLSIntegratedTimelineUpdateReason {
        guard
            let reason = notification.userInfo?[
                AVPlayerItemIntegratedTimeline
                    .snapshotsOutOfSyncReasonKey
            ] as? AVPlayerIntegratedTimelineSnapshotsOutOfSyncReason
        else {
            return .other
        }
        switch reason {
        case .segmentsChanged:
            return .segmentsChanged
        case .currentSegmentChanged:
            return .currentSegmentChanged
        case .loadedTimeRangesChanged:
            return .loadedTimeRangesChanged
        default:
            return .other
        }
    }

    static func kind(
        _ nativeKind: AVPlayerItemSegment.SegmentType
    ) -> HLSIntegratedTimelineSegmentKind {
        switch nativeKind {
        case .primary:
            return .primary
        case .interstitial:
            return .interstitial
        @unknown default:
            return .other
        }
    }

    static func boundedIdentifier(
        _ value: String?
    ) -> (value: String?, wasTruncated: Bool) {
        guard let value else {
            return (nil, false)
        }
        guard value.utf8.count > maximumIdentifierUTF8ByteCount else {
            return (value, false)
        }
        var result = ""
        result.reserveCapacity(
            min(value.count, maximumIdentifierUTF8ByteCount)
        )
        var byteCount = 0
        for character in value {
            let characterByteCount = String(character).utf8.count
            guard
                byteCount + characterByteCount
                    <= maximumIdentifierUTF8ByteCount
            else {
                break
            }
            result.append(character)
            byteCount += characterByteCount
        }
        return (result, true)
    }
}
