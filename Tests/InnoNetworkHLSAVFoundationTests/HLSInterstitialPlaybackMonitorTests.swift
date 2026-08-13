#if canImport(AVFoundation)
import AVFoundation
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@MainActor
@Suite("AVFoundation HLS interstitial playback monitor")
struct HLSInterstitialPlaybackMonitorTests {
    @Test("buffer limits retain both initial snapshots")
    func bufferLimitsRetainInitialSnapshots() async throws {
        #expect(
            HLSInterstitialPlaybackMonitor
                .clampedBufferedEventCount(-1) == 2
        )
        #expect(
            HLSInterstitialPlaybackMonitor
                .clampedBufferedEventCount(64) == 64
        )
        #expect(
            HLSInterstitialPlaybackMonitor
                .clampedBufferedEventCount(2_048) == 1_024
        )

        let monitor = makeMonitor(maximumBufferedEventCount: 1)
        var iterator = monitor.events().makeAsyncIterator()

        #expect(await iterator.next() == .scheduleChanged([]))
        #expect(await iterator.next() == .currentEventChanged(nil))
    }

    @Test("snapshots expose only bounded playback metadata")
    func snapshotsExposeBoundedMetadata() throws {
        let item = AVPlayerItem(url: try sourceURL())
        let event = AVPlayerInterstitialEvent(
            primaryItem: item,
            time: CMTime(seconds: 12.5, preferredTimescale: 600)
        )
        event.identifier = "interstitial-1"
        event.resumptionOffset = CMTime(
            seconds: 3,
            preferredTimescale: 600
        )
        event.playoutLimit = CMTime(
            seconds: 10,
            preferredTimescale: 600
        )

        let snapshot = HLSInterstitialRuntimeMapper.snapshot(event)

        #expect(snapshot.identifier == "interstitial-1")
        #expect(snapshot.scheduledTime == 12.5)
        #expect(snapshot.scheduledDate == nil)
        #expect(snapshot.templateItemCount == 0)
        #expect(snapshot.resumptionOffset == 3)
        #expect(snapshot.playoutLimit == 10)
    }

    @Test("invalid time values are redacted")
    func invalidTimeValuesAreRedacted() {
        #expect(
            HLSInterstitialRuntimeMapper.finite(.indefinite) == nil
        )
        #expect(
            HLSInterstitialRuntimeMapper.finite(.positiveInfinity)
                == nil
        )
        #expect(
            HLSInterstitialRuntimeMapper.finiteNonnegative(
                CMTime(
                    seconds: -1,
                    preferredTimescale: 600
                )
            ) == nil
        )
    }

    @Test("asset-list notifications map status without error values")
    func assetListNotificationsAreRedacted() throws {
        let monitor = nativeMonitor()
        let event = AVPlayerInterstitialEvent(
            primaryItem: AVPlayerItem(url: try sourceURL()),
            time: .zero
        )
        event.identifier = "interstitial-2"
        let notification = Notification(
            name:
                AVPlayerInterstitialEventMonitor
                .assetListResponseStatusDidChangeNotification,
            object: monitor,
            userInfo: [
                AVPlayerInterstitialEventMonitor
                    .assetListResponseStatusDidChangeEventKey: event,
                AVPlayerInterstitialEventMonitor
                    .assetListResponseStatusDidChangeStatusKey:
                    AVPlayerInterstitialEventAssetListResponseStatus
                    .unavailable.rawValue,
                AVPlayerInterstitialEventMonitor
                    .assetListResponseStatusDidChangeErrorKey:
                    TestError(),
            ]
        )

        #expect(
            HLSInterstitialRuntimeMapper.map(
                notification,
                monitor: monitor
            )
                == .assetListStatusChanged(
                    HLSInterstitialRuntimeMapper.snapshot(event),
                    status: .unavailable,
                    hadError: true
                )
        )
    }

    @available(
        macOS 13.3,
        iOS 16.4,
        tvOS 16.4,
        watchOS 9.4,
        visionOS 1,
        *
    )
    @Test("asset-list status changes are observed on supported systems")
    func assetListStatusChangesAreObserved() {
        #expect(
            HLSInterstitialAssetListMapper.notificationNames
                == [
                    AVPlayerInterstitialEventMonitor
                        .assetListResponseStatusDidChangeNotification
                ]
        )
    }

    @available(
        macOS 26,
        iOS 26,
        tvOS 26,
        watchOS 26,
        visionOS 26,
        *
    )
    @Test("new lifecycle notifications map into typed events")
    func newLifecycleNotificationsAreTyped() throws {
        let event = AVPlayerInterstitialEvent(
            primaryItem: AVPlayerItem(url: try sourceURL()),
            time: .zero
        )
        event.identifier = "interstitial-3"

        let skipped = Notification(
            name:
                AVPlayerInterstitialEventMonitor
                .currentEventSkippedNotification,
            userInfo: [
                AVPlayerInterstitialEventMonitor
                    .currentEventSkippedEventKey: event
            ]
        )
        #expect(
            HLSInterstitialRuntimeMapper
                .mapVersion26Notification(skipped)
                == .skipped(
                    HLSInterstitialRuntimeMapper.snapshot(event)
                )
        )

        let finished = Notification(
            name:
                AVPlayerInterstitialEventMonitor
                .interstitialEventDidFinishNotification,
            userInfo: [
                AVPlayerInterstitialEventMonitor
                    .interstitialEventDidFinishEventKey: event,
                AVPlayerInterstitialEventMonitor
                    .interstitialEventDidFinishPlayoutTimeKey:
                    NSValue(
                        time: CMTime(
                            seconds: 5,
                            preferredTimescale: 600
                        )
                    ),
                AVPlayerInterstitialEventMonitor
                    .interstitialEventDidFinishDidPlayEntireEventKey: true,
            ]
        )
        #expect(
            HLSInterstitialRuntimeMapper
                .mapVersion26Notification(finished)
                == .finished(
                    HLSInterstitialRuntimeMapper.snapshot(event),
                    playoutDuration: 5,
                    didPlayEntireEvent: true
                )
        )
    }

    #if compiler(>=6.4)
    @available(
        macOS 26.4,
        iOS 26.4,
        tvOS 26.4,
        watchOS 26.4,
        visionOS 26.4,
        *
    )
    @Test("schedule request completion is observed on supported SDKs")
    func scheduleRequestCompletionIsObserved() {
        #expect(
            HLSInterstitialScheduleRequestMapper
                .notificationNames
                == [
                    AVPlayerInterstitialEventMonitor
                        .ScheduleRequestCompleted.name
                ]
        )
    }
    #endif

    private func makeMonitor(
        maximumBufferedEventCount: Int = 64
    ) -> HLSInterstitialPlaybackMonitor {
        HLSInterstitialPlaybackMonitor(
            monitor: nativeMonitor(),
            notificationCenter: NotificationCenter(),
            maximumBufferedEventCount: maximumBufferedEventCount
        )
    }

    private func nativeMonitor() -> AVPlayerInterstitialEventMonitor {
        AVPlayerInterstitialEventMonitor(primaryPlayer: AVPlayer())
    }

    private func sourceURL() throws -> URL {
        try #require(
            URL(string: "https://media.example/live.m3u8")
        )
    }
}

private struct TestError: Error {}
#endif
