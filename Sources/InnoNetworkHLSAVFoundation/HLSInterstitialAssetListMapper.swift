import AVFoundation
import Foundation

/// Isolates asset-list lifecycle APIs from the package's platform floors.
@MainActor
enum HLSInterstitialAssetListMapper {
    static var notificationNames: [Notification.Name] {
        if #available(macOS 13.3,
        iOS 16.4,
        tvOS 16.4,
        watchOS 9.4,
        visionOS 1,
        *) {
            return [
                AVPlayerInterstitialEventMonitor
                    .assetListResponseStatusDidChangeNotification
            ]
        }
        return []
    }

    static func map(
        _ notification: Notification
    ) -> HLSInterstitialRuntimeEvent? {
        if #available(macOS 13.3,
        iOS 16.4,
        tvOS 16.4,
        watchOS 9.4,
        visionOS 1,
        *),
            notification.name
                == AVPlayerInterstitialEventMonitor
                .assetListResponseStatusDidChangeNotification
        {
            return mapAvailable(notification)
        }
        return nil
    }

    @available(
        macOS 13.3,
        iOS 16.4,
        tvOS 16.4,
        watchOS 9.4,
        visionOS 1,
        *
    )
    private static func mapAvailable(
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
            HLSInterstitialRuntimeMapper.snapshot(event),
            status: status,
            hadError:
                notification.userInfo?[
                    AVPlayerInterstitialEventMonitor
                        .assetListResponseStatusDidChangeErrorKey
                ] != nil
        )
    }
}
