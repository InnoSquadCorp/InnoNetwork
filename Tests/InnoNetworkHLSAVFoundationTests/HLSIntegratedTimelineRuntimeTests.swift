#if canImport(AVFoundation) && (os(macOS) || os(iOS))
import AVFoundation
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@MainActor
@Suite("Integrated HLS timeline runtime")
struct HLSIntegratedTimelineRuntimeTests {
    @available(macOS 27, iOS 27, *)
    @Test(
        "AVPlayer advances a primary segment on the integrated timeline",
        .timeLimit(.minutes(1))
    )
    func avPlayerAdvancesIntegratedTimeline() async throws {
        guard
            let rawURL = ProcessInfo.processInfo.environment[
                "INNONETWORK_HLS_RUNTIME_PLAYLIST_URL"
            ],
            let playlistURL = URL(string: rawURL)
        else {
            try Test.cancel()
        }

        let playerItem = AVPlayerItem(url: playlistURL)
        let player = AVPlayer(playerItem: playerItem)
        let controller = AVPlayerInterstitialEventController(
            primaryPlayer: player
        )
        let event = AVPlayerInterstitialEvent(
            primaryItem: playerItem,
            time: CMTime(seconds: 0.5, preferredTimescale: 600)
        )
        event.identifier = "runtime-interstitial"
        event.templateItems = [AVPlayerItem(url: playlistURL)]
        event.playoutLimit = CMTime(
            seconds: 0.25,
            preferredTimescale: 600
        )
        event.timelineOccupancy = .fill
        controller.events = [event]
        defer {
            player.pause()
        }
        let result = try await observedPlayback(
            playerItem: playerItem,
            player: player
        )

        #expect(
            result.0.segments[result.1].kind
                == .primary
        )
        let interstitial = try #require(
            result.0.segments.first {
                $0.kind == .interstitial
            }
        )
        #expect(
            interstitial.interstitialIdentifier
                == "runtime-interstitial"
        )
        #expect(interstitial.timelineTimeRange?.isEmpty == false)
        #expect(result.0.duration != nil)
        _ = controller
    }

    @available(macOS 27, iOS 27, *)
    private func observedPlayback(
        playerItem: AVPlayerItem,
        player: AVPlayer
    ) async throws -> (HLSIntegratedTimelineSnapshot, Int) {
        let monitor = HLSIntegratedTimelineMonitor(
            playerItem: playerItem,
            updateInterval: 0.1
        )
        var result: (HLSIntegratedTimelineSnapshot, Int)?
        var observedInterstitial = false
        do {
            var updates = monitor.updates().makeAsyncIterator()
            player.play()
            while let update = await updates.next() {
                observedInterstitial =
                    observedInterstitial
                    || update.snapshot.segments.contains {
                        $0.kind == .interstitial
                    }
                guard
                    observedInterstitial,
                    update.reason == .playheadChanged,
                    let currentTime = update.snapshot.currentTime,
                    currentTime > 0,
                    let currentIndex = update.snapshot.currentSegmentIndex
                else {
                    continue
                }
                result = (update.snapshot, currentIndex)
                break
            }
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        try await Task.sleep(for: .milliseconds(10))
        return try #require(result)
    }
}
#endif
