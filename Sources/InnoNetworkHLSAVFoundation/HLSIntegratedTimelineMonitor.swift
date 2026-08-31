import AVFoundation
import Foundation

/// Observes the caller-owned player's integrated primary/interstitial timeline.
///
/// The monitor is read-only. AVFoundation and the caller retain ownership of
/// playback, seeking, interstitial scheduling, and navigation policy.
@available(
    macOS 15,
    iOS 18,
    tvOS 18,
    watchOS 11,
    visionOS 2,
    *
)
@MainActor
public final class HLSIntegratedTimelineMonitor {
    private let playerItem: AVPlayerItem
    private let timeline: AVPlayerItemIntegratedTimeline
    private let notificationCenter: NotificationCenter
    private let updateInterval: Duration
    private let maximumBufferedUpdateCount: Int

    /// Creates a read-only monitor for one caller-owned primary player item.
    ///
    /// The update interval is clamped to `0.1...60` seconds and defaults to
    /// half a second when it is not finite. The per-subscriber buffer is
    /// clamped to `2...1,024`. The monitor retains the item for its observation
    /// lifetime without taking over playback ownership.
    public init(
        playerItem: AVPlayerItem,
        updateInterval: TimeInterval = 0.5,
        maximumBufferedUpdateCount: Int = 64
    ) {
        self.playerItem = playerItem
        self.timeline = playerItem.integratedTimeline
        self.notificationCenter = .default
        self.updateInterval = .seconds(
            Self.normalizedUpdateInterval(updateInterval)
        )
        self.maximumBufferedUpdateCount =
            Self.clampedBufferedUpdateCount(
                maximumBufferedUpdateCount
            )
    }

    init(
        playerItem: AVPlayerItem,
        notificationCenter: NotificationCenter = .default,
        updateInterval: TimeInterval = 0.5,
        maximumBufferedUpdateCount: Int = 64
    ) {
        self.playerItem = playerItem
        self.timeline = playerItem.integratedTimeline
        self.notificationCenter = notificationCenter
        self.updateInterval = .seconds(
            Self.normalizedUpdateInterval(updateInterval)
        )
        self.maximumBufferedUpdateCount =
            Self.clampedBufferedUpdateCount(
                maximumBufferedUpdateCount
            )
    }

    /// The latest integrated-timeline state at the time of access.
    public var currentSnapshot: HLSIntegratedTimelineSnapshot {
        HLSIntegratedTimelineMapper.snapshot(
            timeline.currentSnapshot
        )
    }

    /// Starts one independent, cancellation-safe update stream.
    ///
    /// The stream first emits the current snapshot. Later snapshots report
    /// playhead progress and native timeline invalidations. When a consumer
    /// falls behind, newer updates replace older buffered values.
    public func updates()
        -> AsyncStream<HLSIntegratedTimelineUpdate>
    {
        let (stream, continuation) =
            AsyncStream<
                HLSIntegratedTimelineUpdate
            >.makeStream(
                bufferingPolicy: .bufferingNewest(
                    maximumBufferedUpdateCount
                )
            )
        let timeline = timeline
        let playerItem = playerItem
        let notificationCenter = notificationCenter
        let invalidations = notificationCenter.notifications(
            named:
                AVPlayerItemIntegratedTimeline
                .snapshotsOutOfSyncNotification,
            object: timeline
        )
        let initialSnapshot = HLSIntegratedTimelineMapper.snapshot(
            timeline.currentSnapshot
        )
        continuation.yield(
            HLSIntegratedTimelineUpdate(
                reason: .initial,
                snapshot: initialSnapshot
            )
        )

        let periodicTask = Task { @MainActor in
            var previousSnapshot = initialSnapshot
            while !Task.isCancelled {
                do {
                    try await ContinuousClock().sleep(
                        for: updateInterval
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                let snapshot = HLSIntegratedTimelineMapper.snapshot(
                    timeline.currentSnapshot
                )
                let didPlayheadChange =
                    snapshot.currentTime
                    != previousSnapshot.currentTime
                    || snapshot.currentDate
                        != previousSnapshot.currentDate
                    || snapshot.currentSegmentIndex
                        != previousSnapshot.currentSegmentIndex
                previousSnapshot = snapshot
                guard didPlayheadChange else {
                    continue
                }
                continuation.yield(
                    HLSIntegratedTimelineUpdate(
                        reason: .playheadChanged,
                        snapshot: snapshot
                    )
                )
            }
            _ = playerItem
        }
        let invalidationTask = Task { @MainActor in
            for await notification in invalidations {
                guard !Task.isCancelled else {
                    return
                }
                continuation.yield(
                    Self.update(
                        timeline: timeline,
                        reason:
                            HLSIntegratedTimelineMapper.updateReason(
                                notification
                            )
                    )
                )
            }
        }
        continuation.onTermination = { _ in
            periodicTask.cancel()
            invalidationTask.cancel()
        }
        return stream
    }

    static func clampedBufferedUpdateCount(_ value: Int) -> Int {
        min(1_024, max(2, value))
    }

    static func normalizedUpdateInterval(
        _ value: TimeInterval
    ) -> TimeInterval {
        if value.isFinite {
            return min(60, max(0.1, value))
        }
        return 0.5
    }

    private static func update(
        timeline: AVPlayerItemIntegratedTimeline,
        reason: HLSIntegratedTimelineUpdateReason
    ) -> HLSIntegratedTimelineUpdate {
        HLSIntegratedTimelineUpdate(
            reason: reason,
            snapshot: HLSIntegratedTimelineMapper.snapshot(
                timeline.currentSnapshot
            )
        )
    }
}
