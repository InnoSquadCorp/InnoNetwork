import AVFoundation
import Foundation

/// Observes server-authored or application-authored interstitial playback.
///
/// The monitor is read-only: it does not replace the interstitial schedule,
/// cancel playback, or invoke skip controls.
@MainActor
public final class HLSInterstitialPlaybackMonitor {
    private let monitor: AVPlayerInterstitialEventMonitor
    private let notificationCenter: NotificationCenter
    private let maximumBufferedEventCount: Int

    /// Creates a read-only monitor for one caller-owned primary player.
    ///
    /// The buffer limit is clamped to `2...1,024` so the initial schedule and
    /// current-event snapshots are both retained. The caller must retain the
    /// player and this bridge for the desired observation lifetime.
    public init(
        primaryPlayer: AVPlayer,
        maximumBufferedEventCount: Int = 64
    ) {
        self.monitor = AVPlayerInterstitialEventMonitor(
            primaryPlayer: primaryPlayer
        )
        self.notificationCenter = .default
        self.maximumBufferedEventCount =
            Self.clampedBufferedEventCount(
                maximumBufferedEventCount
            )
    }

    init(
        monitor: AVPlayerInterstitialEventMonitor,
        notificationCenter: NotificationCenter = .default,
        maximumBufferedEventCount: Int = 64
    ) {
        self.monitor = monitor
        self.notificationCenter = notificationCenter
        self.maximumBufferedEventCount =
            Self.clampedBufferedEventCount(
                maximumBufferedEventCount
            )
    }

    static func clampedBufferedEventCount(_ value: Int) -> Int {
        min(1_024, max(2, value))
    }

    /// Starts one independent, cancellation-safe lifecycle stream.
    ///
    /// The stream first yields the current schedule and current event. When a
    /// consumer falls behind, the newest events replace older buffered values.
    public func events()
        -> AsyncStream<HLSInterstitialRuntimeEvent>
    {
        let (stream, continuation) =
            AsyncStream<
                HLSInterstitialRuntimeEvent
            >.makeStream(
                bufferingPolicy: .bufferingNewest(
                    maximumBufferedEventCount
                )
            )
        let monitor = monitor
        let notificationCenter = notificationCenter
        continuation.yield(
            .scheduleChanged(
                monitor.events.map(
                    HLSInterstitialRuntimeMapper.snapshot
                )
            )
        )
        continuation.yield(
            .currentEventChanged(
                monitor.currentEvent.map(
                    HLSInterstitialRuntimeMapper.snapshot
                )
            )
        )

        let observationTasks = Self.observationTasks(
            monitor: monitor,
            notificationCenter: notificationCenter,
            continuation: continuation
        )
        continuation.onTermination = { _ in
            for task in observationTasks {
                task.cancel()
            }
        }
        return stream
    }

    private static func observationTasks(
        monitor: AVPlayerInterstitialEventMonitor,
        notificationCenter: NotificationCenter,
        continuation:
            AsyncStream<
                HLSInterstitialRuntimeEvent
            >.Continuation
    ) -> [Task<Void, Never>] {
        var tasks: [Task<Void, Never>] = []
        for name in notificationNames {
            tasks.append(
                Task { @MainActor in
                    for await notification in notificationCenter.notifications(
                        named: name,
                        object: monitor
                    ) {
                        guard !Task.isCancelled else {
                            return
                        }
                        if let event =
                            HLSInterstitialRuntimeMapper.map(
                                notification,
                                monitor: monitor
                            )
                        {
                            continuation.yield(event)
                        }
                    }
                }
            )
        }
        return tasks
    }

    private static var notificationNames: [Notification.Name] {
        var names: [Notification.Name] = [
            AVPlayerInterstitialEventMonitor
                .eventsDidChangeNotification,
            AVPlayerInterstitialEventMonitor
                .currentEventDidChangeNotification,
            AVPlayerInterstitialEventMonitor
                .assetListResponseStatusDidChangeNotification,
        ]
        if #available(macOS 26,
        iOS 26,
        tvOS 26,
        watchOS 26,
        visionOS 26,
        *) {
            names.append(
                contentsOf: [
                    AVPlayerInterstitialEventMonitor
                        .currentEventSkippableStateDidChangeNotification,
                    AVPlayerInterstitialEventMonitor
                        .currentEventSkippedNotification,
                    AVPlayerInterstitialEventMonitor
                        .interstitialEventWasUnscheduledNotification,
                    AVPlayerInterstitialEventMonitor
                        .interstitialEventDidFinishNotification,
                ]
            )
        }
        if #available(macOS 26.4,
        iOS 26.4,
        tvOS 26.4,
        watchOS 26.4,
        visionOS 26.4,
        *) {
            names.append(
                AVPlayerInterstitialEventMonitor
                    .ScheduleRequestCompleted.name
            )
        }
        return names
    }
}

@MainActor
enum HLSInterstitialRuntimeMapper {
    static func map(
        _ notification: Notification,
        monitor: AVPlayerInterstitialEventMonitor
    ) -> HLSInterstitialRuntimeEvent? {
        switch notification.name {
        case AVPlayerInterstitialEventMonitor
            .eventsDidChangeNotification:
            return .scheduleChanged(
                monitor.events.map(snapshot)
            )
        case AVPlayerInterstitialEventMonitor
            .currentEventDidChangeNotification:
            return .currentEventChanged(
                monitor.currentEvent.map(snapshot)
            )
        case AVPlayerInterstitialEventMonitor
            .assetListResponseStatusDidChangeNotification:
            return mapAssetList(notification)
        default:
            return mapNewerNotification(notification)
        }
    }

    private static func mapNewerNotification(
        _ notification: Notification
    ) -> HLSInterstitialRuntimeEvent? {
        if #available(macOS 26,
        iOS 26,
        tvOS 26,
        watchOS 26,
        visionOS 26,
        *) {
            return mapVersion26Notification(notification)
        }
        return nil
    }

    static func snapshot(
        _ event: AVPlayerInterstitialEvent
    ) -> HLSInterstitialEventSnapshot {
        HLSInterstitialEventSnapshot(
            identifier: event.identifier,
            scheduledTime: finite(event.time),
            scheduledDate: event.date,
            templateItemCount: max(0, event.templateItems.count),
            resumptionOffset: finite(event.resumptionOffset),
            playoutLimit: finiteNonnegative(event.playoutLimit)
        )
    }

    private static func mapAssetList(
        _ notification: Notification
    ) -> HLSInterstitialRuntimeEvent? {
        guard
            let event = notification.userInfo?[
                AVPlayerInterstitialEventMonitor
                    .assetListResponseStatusDidChangeEventKey
            ] as? AVPlayerInterstitialEvent,
            let rawStatus =
                (notification.userInfo?[
                    AVPlayerInterstitialEventMonitor
                        .assetListResponseStatusDidChangeStatusKey
                ] as? NSNumber)?.intValue
        else {
            return nil
        }
        let status: HLSInterstitialAssetListStatus
        switch AVPlayerInterstitialEventAssetListResponseStatus(
            rawValue: rawStatus
        ) {
        case .available:
            status = .available
        case .cleared:
            status = .cleared
        case .unavailable:
            status = .unavailable
        default:
            status = .other
        }
        return .assetListStatusChanged(
            snapshot(event),
            status: status,
            hadError:
                notification.userInfo?[
                    AVPlayerInterstitialEventMonitor
                        .assetListResponseStatusDidChangeErrorKey
                ] != nil
        )
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

@available(
    macOS 26,
    iOS 26,
    tvOS 26,
    watchOS 26,
    visionOS 26,
    *
)
@MainActor
extension HLSInterstitialRuntimeMapper {
    static func mapVersion26Notification(
        _ notification: Notification
    ) -> HLSInterstitialRuntimeEvent? {
        switch notification.name {
        case AVPlayerInterstitialEventMonitor
            .currentEventSkippableStateDidChangeNotification:
            return mapSkippable(notification)
        case AVPlayerInterstitialEventMonitor
            .currentEventSkippedNotification:
            return event(
                in: notification,
                key:
                    AVPlayerInterstitialEventMonitor
                    .currentEventSkippedEventKey
            ).map {
                .skipped(snapshot($0))
            }
        case AVPlayerInterstitialEventMonitor
            .interstitialEventWasUnscheduledNotification:
            return event(
                in: notification,
                key:
                    AVPlayerInterstitialEventMonitor
                    .interstitialEventWasUnscheduledEventKey
            ).map {
                .unscheduled(
                    snapshot($0),
                    hadError:
                        notification.userInfo?[
                            AVPlayerInterstitialEventMonitor
                                .interstitialEventWasUnscheduledErrorKey
                        ] != nil
                )
            }
        case AVPlayerInterstitialEventMonitor
            .interstitialEventDidFinishNotification:
            return mapFinished(notification)
        default:
            if #available(macOS 26.4,
            iOS 26.4,
            tvOS 26.4,
            watchOS 26.4,
            visionOS 26.4,
            *),
                notification.name
                    == AVPlayerInterstitialEventMonitor
                    .ScheduleRequestCompleted.name
            {
                guard
                    let message =
                        AVPlayerInterstitialEventMonitor
                        .ScheduleRequestCompleted.makeMessage(
                            notification
                        )
                else {
                    return nil
                }
                let succeeded: Bool
                switch message.result {
                case .success:
                    succeeded = true
                case .failure:
                    succeeded = false
                }
                return .scheduleRequestCompleted(
                    succeeded: succeeded
                )
            }
            return nil
        }
    }

    static func mapSkippable(
        _ notification: Notification
    ) -> HLSInterstitialRuntimeEvent? {
        guard
            let event = event(
                in: notification,
                key:
                    AVPlayerInterstitialEventMonitor
                    .currentEventSkippableStateDidChangeEventKey
            ),
            let rawState =
                (notification.userInfo?[
                    AVPlayerInterstitialEventMonitor
                        .currentEventSkippableStateDidChangeStateKey
                ] as? NSNumber)?.intValue
        else {
            return nil
        }
        let state: HLSInterstitialSkippableState
        switch AVPlayerInterstitialEvent.SkippableEventState(
            rawValue: rawState
        ) {
        case .notSkippable:
            state = .notSkippable
        case .notYetEligible:
            state = .notYetEligible
        case .eligible:
            state = .eligible
        case .noLongerEligible:
            state = .noLongerEligible
        default:
            state = .other
        }
        return .skippableStateChanged(
            snapshot(event),
            state: state
        )
    }

    static func mapFinished(
        _ notification: Notification
    ) -> HLSInterstitialRuntimeEvent? {
        guard
            let event = event(
                in: notification,
                key:
                    AVPlayerInterstitialEventMonitor
                    .interstitialEventDidFinishEventKey
            )
        else {
            return nil
        }
        let playoutTime = notification.userInfo?[
            AVPlayerInterstitialEventMonitor
                .interstitialEventDidFinishPlayoutTimeKey
        ]
        let time: CMTime?
        if let value = playoutTime as? NSValue {
            time = value.timeValue
        } else {
            time = playoutTime as? CMTime
        }
        let didPlayEntireEvent =
            (notification.userInfo?[
                AVPlayerInterstitialEventMonitor
                    .interstitialEventDidFinishDidPlayEntireEventKey
            ] as? NSNumber)?.boolValue ?? false
        return .finished(
            snapshot(event),
            playoutDuration: time.flatMap(finiteNonnegative),
            didPlayEntireEvent: didPlayEntireEvent
        )
    }

    static func event(
        in notification: Notification,
        key: String
    ) -> AVPlayerInterstitialEvent? {
        notification.userInfo?[key]
            as? AVPlayerInterstitialEvent
    }
}
