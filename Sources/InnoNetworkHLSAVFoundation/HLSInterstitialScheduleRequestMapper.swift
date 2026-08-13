import AVFoundation
import Foundation

/// Isolates SDK-new typed notifications from the package's Xcode 26 floor.
enum HLSInterstitialScheduleRequestMapper {
    static var notificationNames: [Notification.Name] {
        #if compiler(>=6.4)
        if #available(macOS 26.4,
        iOS 26.4,
        tvOS 26.4,
        watchOS 26.4,
        visionOS 26.4,
        *) {
            return [
                AVPlayerInterstitialEventMonitor
                    .ScheduleRequestCompleted.name
            ]
        }
        #endif
        return []
    }

    static func map(
        _ notification: Notification
    ) -> HLSInterstitialRuntimeEvent? {
        #if compiler(>=6.4)
        if #available(macOS 26.4,
        iOS 26.4,
        tvOS 26.4,
        watchOS 26.4,
        visionOS 26.4,
        *),
            notification.name
                == AVPlayerInterstitialEventMonitor
                .ScheduleRequestCompleted.name,
            let message =
                AVPlayerInterstitialEventMonitor
                .ScheduleRequestCompleted.makeMessage(notification)
        {
            switch message.result {
            case .success:
                return .scheduleRequestCompleted(succeeded: true)
            case .failure:
                return .scheduleRequestCompleted(succeeded: false)
            }
        }
        #endif
        return nil
    }
}
