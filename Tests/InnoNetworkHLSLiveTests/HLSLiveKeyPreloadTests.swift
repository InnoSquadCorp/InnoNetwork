import Foundation
import InnoNetworkHLS
import Testing

@testable import InnoNetworkHLSLive

@Suite("HLS live key preloading")
struct HLSLiveKeyPreloadTests {
    @Test("key preloads are spread across the projected first-use window")
    func spreadsKeyPreloadAcrossWindow() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live.m3u8")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-PROGRAM-DATE-TIME:2026-08-06T12:00:00Z
            #EXTINF:4,
            current.ts
            #EXT-X-PRELOAD-HINT:TYPE=KEY,URI="next.key",METHOD=AES-128,DATE-OF-FIRST-USE="2026-08-06T12:00:08Z"
            """,
            relativeTo: sourceURL
        )
        let hint = try #require(
            playlist.lowLatency?.preloadHints.first
        )
        let preloader = HLSLiveKeyPreloadRecorder()
        let sleeps = HLSLiveSleepRecorder()
        let coordinator = HLSLiveKeyPreloadCoordinator(
            preloader: preloader,
            sleep: { duration in
                await sleeps.record(duration)
            },
            randomUnitInterval: { 0.5 }
        )
        let snapshot = HLSLivePlaylistSnapshot(
            playlist: playlist,
            segments: [
                HLSLiveSegment(
                    sequenceNumber: 0,
                    duration: 4,
                    url: sourceURL,
                    byteRange: nil,
                    beginsDiscontinuity: false,
                    isGap: false
                )
            ],
            partialSegments: [],
            dateRanges: [],
            generation: 0,
            isDeltaUpdate: false,
            isEnded: false
        )

        await coordinator.update(after: snapshot)
        await coordinator.update(after: snapshot)
        for _ in 0..<100 {
            if !(await preloader.hints()).isEmpty {
                break
            }
            await Task.yield()
        }

        #expect(await sleeps.durations() == [.seconds(2)])
        #expect(await preloader.hints() == [hint])
        await coordinator.cancelAll()
    }

    @Test("removing a hint cancels its pending callback")
    func cancelsRemovedKeyPreload() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live.m3u8")
        )
        let hintedPlaylist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-PRELOAD-HINT:TYPE=KEY,URI="next.key",METHOD=AES-128
            """,
            relativeTo: sourceURL
        )
        let clearedPlaylist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXTINF:4,
            current.ts
            """,
            relativeTo: sourceURL
        )
        let preloader = HLSLiveKeyPreloadRecorder()
        let coordinator = HLSLiveKeyPreloadCoordinator(
            preloader: preloader,
            sleep: { _ in
                try await ContinuousClock().sleep(
                    for: .seconds(3_600)
                )
            },
            randomUnitInterval: { 1 }
        )

        await coordinator.update(
            after: snapshot(
                playlist: hintedPlaylist
            )
        )
        await coordinator.update(
            after: snapshot(
                playlist: clearedPlaylist
            )
        )
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(await preloader.hints().isEmpty)
        await coordinator.cancelAll()
    }

    private func snapshot(
        playlist: HLSPlaylist
    ) -> HLSLivePlaylistSnapshot {
        HLSLivePlaylistSnapshot(
            playlist: playlist,
            segments: [],
            partialSegments: [],
            dateRanges: [],
            generation: 0,
            isDeltaUpdate: false,
            isEnded: false
        )
    }
}

private actor HLSLiveKeyPreloadRecorder:
    HLSLiveEncryptionKeyPreloading
{
    private var recordedHints: [HLSPreloadHint] = []

    func preloadEncryptionKey(
        for hint: HLSPreloadHint
    ) {
        recordedHints.append(hint)
    }

    func hints() -> [HLSPreloadHint] {
        recordedHints
    }
}

private actor HLSLiveSleepRecorder {
    private var recordedDurations: [Duration] = []

    func record(_ duration: Duration) {
        recordedDurations.append(duration)
    }

    func durations() -> [Duration] {
        recordedDurations
    }
}
