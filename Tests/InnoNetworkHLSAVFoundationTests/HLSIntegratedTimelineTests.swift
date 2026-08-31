#if canImport(AVFoundation)
import AVFoundation
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@MainActor
@Suite("AVFoundation HLS integrated timeline")
struct HLSIntegratedTimelineTests {
    @available(
        macOS 15,
        iOS 18,
        tvOS 18,
        watchOS 11,
        visionOS 2,
        *
    )
    @Test("configuration bounds protect update delivery")
    func configurationBoundsProtectDelivery() {
        #expect(
            HLSIntegratedTimelineMonitor
                .clampedBufferedUpdateCount(-1) == 2
        )
        #expect(
            HLSIntegratedTimelineMonitor
                .clampedBufferedUpdateCount(64) == 64
        )
        #expect(
            HLSIntegratedTimelineMonitor
                .clampedBufferedUpdateCount(2_048) == 1_024
        )
        #expect(
            HLSIntegratedTimelineMonitor
                .normalizedUpdateInterval(.nan) == 0.5
        )
        #expect(
            HLSIntegratedTimelineMonitor
                .normalizedUpdateInterval(0) == 0.1
        )
        #expect(
            HLSIntegratedTimelineMonitor
                .normalizedUpdateInterval(100) == 60
        )
    }

    @available(
        macOS 15,
        iOS 18,
        tvOS 18,
        watchOS 11,
        visionOS 2,
        *
    )
    @Test("interstitial identifiers remain valid UTF-8 when bounded")
    func interstitialIdentifiersRemainValidUTF8() {
        let exact = String(
            repeating: "a",
            count:
                HLSIntegratedTimelineMapper
                .maximumIdentifierUTF8ByteCount
        )
        #expect(
            HLSIntegratedTimelineMapper.boundedIdentifier(exact)
                .value == exact
        )
        #expect(
            !HLSIntegratedTimelineMapper.boundedIdentifier(exact)
                .wasTruncated
        )

        let oversized = exact + "한"
        let bounded = HLSIntegratedTimelineMapper.boundedIdentifier(
            oversized
        )
        #expect(bounded.value == exact)
        #expect(bounded.wasTruncated)
        #expect(bounded.value?.utf8.count == exact.utf8.count)
    }

    @available(
        macOS 15,
        iOS 18,
        tvOS 18,
        watchOS 11,
        visionOS 2,
        *
    )
    @Test("time ranges reject invalid and unsafe values")
    func timeRangesRejectInvalidValues() {
        #expect(
            HLSIntegratedTimelineMapper.timeRange(
                CMTimeRange(
                    start: CMTime(seconds: 2, preferredTimescale: 600),
                    duration: CMTime(
                        seconds: 3,
                        preferredTimescale: 600
                    )
                )
            ) == 2..<5
        )
        #expect(
            HLSIntegratedTimelineMapper.timeRange(
                CMTimeRange(start: .zero, duration: .zero)
            ) == 0..<0
        )
        #expect(
            HLSIntegratedTimelineMapper.timeRange(
                CMTimeRange(start: .invalid, duration: .zero)
            ) == nil
        )
        #expect(
            HLSIntegratedTimelineMapper.timeRange(
                CMTimeRange(
                    start: .zero,
                    duration: CMTime(
                        seconds: -1,
                        preferredTimescale: 600
                    )
                )
            ) == nil
        )
        #expect(
            HLSIntegratedTimelineMapper.timeRange(
                CMTimeRange(start: .zero, duration: .indefinite)
            ) == nil
        )
    }

    @available(
        macOS 15,
        iOS 18,
        tvOS 18,
        watchOS 11,
        visionOS 2,
        *
    )
    @Test("native invalidation reasons map without raw values")
    func nativeInvalidationReasonsAreTyped() {
        let name = AVPlayerItemIntegratedTimeline
            .snapshotsOutOfSyncNotification
        let key = AVPlayerItemIntegratedTimeline
            .snapshotsOutOfSyncReasonKey

        #expect(
            HLSIntegratedTimelineMapper.updateReason(
                Notification(
                    name: name,
                    userInfo: [
                        key:
                            AVPlayerIntegratedTimelineSnapshotsOutOfSyncReason
                            .segmentsChanged
                    ]
                )
            ) == .segmentsChanged
        )
        #expect(
            HLSIntegratedTimelineMapper.updateReason(
                Notification(
                    name: name,
                    userInfo: [
                        key:
                            AVPlayerIntegratedTimelineSnapshotsOutOfSyncReason
                            .currentSegmentChanged
                    ]
                )
            ) == .currentSegmentChanged
        )
        #expect(
            HLSIntegratedTimelineMapper.updateReason(
                Notification(
                    name: name,
                    userInfo: [
                        key:
                            AVPlayerIntegratedTimelineSnapshotsOutOfSyncReason
                            .loadedTimeRangesChanged
                    ]
                )
            ) == .loadedTimeRangesChanged
        )
        #expect(
            HLSIntegratedTimelineMapper.updateReason(
                Notification(name: name)
            ) == .other
        )
    }

    @available(
        macOS 15,
        iOS 18,
        tvOS 18,
        watchOS 11,
        visionOS 2,
        *
    )
    @Test("updates begin with a complete point-in-time snapshot")
    func updatesBeginWithCurrentSnapshot() async throws {
        let (monitor, player) = try makeMonitor()
        let expected = monitor.currentSnapshot
        let observation = Task<
            HLSIntegratedTimelineUpdate?, Never
        > { @MainActor in
            for await update in monitor.updates() {
                return update
            }
            return nil
        }
        let update = try #require(await observation.value)

        #expect(update.reason == .initial)
        #expect(update.snapshot == expected)
        #expect(
            update.snapshot.segments.count
                <= HLSIntegratedTimelineMapper.maximumSegmentCount
        )
        _ = player
    }

    @available(
        macOS 15,
        iOS 18,
        tvOS 18,
        watchOS 11,
        visionOS 2,
        *
    )
    @Test("snapshot invalidations emit the latest bounded state")
    func snapshotInvalidationsEmitLatestState() async throws {
        let notificationCenter = NotificationCenter()
        let item = AVPlayerItem(url: try sourceURL())
        let player = AVPlayer(playerItem: item)
        let timeline = item.integratedTimeline
        let monitor = HLSIntegratedTimelineMonitor(
            playerItem: item,
            notificationCenter: notificationCenter
        )
        let observation = Task<
            HLSIntegratedTimelineUpdate?, Never
        > { @MainActor in
            for await update in monitor.updates() {
                guard update.reason == .segmentsChanged else {
                    continue
                }
                return update
            }
            return nil
        }
        await Task.yield()

        notificationCenter.post(
            name:
                AVPlayerItemIntegratedTimeline
                .snapshotsOutOfSyncNotification,
            object: timeline,
            userInfo: [
                AVPlayerItemIntegratedTimeline
                    .snapshotsOutOfSyncReasonKey:
                    AVPlayerIntegratedTimelineSnapshotsOutOfSyncReason
                    .segmentsChanged
            ]
        )
        let update = try #require(await observation.value)

        #expect(update.reason == .segmentsChanged)
        #expect(update.snapshot == monitor.currentSnapshot)
        _ = player
    }

    @available(
        macOS 15,
        iOS 18,
        tvOS 18,
        watchOS 11,
        visionOS 2,
        *
    )
    @Test("cancelling a subscriber terminates its independent stream")
    func cancellingSubscriberTerminatesStream() async throws {
        let (monitor, player) = try makeMonitor()
        let stream = monitor.updates()
        let task = Task { @MainActor in
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            return await iterator.next()
        }
        await Task.yield()
        task.cancel()

        #expect(await task.value == nil)
        _ = player
    }

    @available(
        macOS 15,
        iOS 18,
        tvOS 18,
        watchOS 11,
        visionOS 2,
        *
    )
    private func makeMonitor() throws -> (
        HLSIntegratedTimelineMonitor,
        AVPlayer
    ) {
        let item = AVPlayerItem(url: try sourceURL())
        let player = AVPlayer(playerItem: item)
        return (
            HLSIntegratedTimelineMonitor(playerItem: item),
            player
        )
    }

    @available(
        macOS 15,
        iOS 18,
        tvOS 18,
        watchOS 11,
        visionOS 2,
        *
    )
    private func sourceURL() throws -> URL {
        try #require(
            URL(string: "https://media.example/live.m3u8")
        )
    }
}
#endif
