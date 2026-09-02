#if canImport(AVFoundation) && canImport(Network)
import AVFoundation
import Foundation
import InnoNetwork
import InnoNetworkHLSAVFoundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import InnoNetworkHLSLive

@MainActor
@Suite("HLS live DVR timeshift runtime", .serialized)
struct HLSLiveDVRTimeshiftRuntimeTests {
    @Test(
        "an in-progress DVR snapshot advances through AVPlayer",
        .hlsRuntimeURL("INNONETWORK_HLS_LIVE_TIMESHIFT_RUNTIME_URL"),
        .timeLimit(.minutes(1))
    )
    func capturesAndPlaysInProgressSnapshot() async throws {
        let playlistURL = try hlsRuntimeURL(
            environmentKey:
                "INNONETWORK_HLS_LIVE_TIMESHIFT_RUNTIME_URL"
        )

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "innonetwork-live-timeshift-\(UUID().uuidString)",
                isDirectory: true
            )
        let destinationURL = rootURL.appendingPathComponent(
            "recording",
            isDirectory: true
        )
        let snapshotURL = rootURL.appendingPathComponent(
            "snapshot",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let requestContext = NetworkRequestContext(
            requestID: UUID(),
            retryIndex: 0,
            metricsReporter: nil,
            trustPolicy: .systemDefault,
            eventObservers: [],
            redirectPolicy: DefaultRedirectPolicy(),
            allowsInsecureHTTP: true,
            allowsAutomaticRedirects: true,
            allowsURLCacheStorage: true
        )
        let client = HLSLivePlaylistClient(
            session: .shared,
            requestContext: requestContext
        )
        let recording = HLSLiveDVRRecorder(
            client: client,
            configuration: .advanced(startPosition: .currentWindow)
        ).startRecording(
            from: playlistURL,
            to: destinationURL
        )
        let snapshot = try await recording.capturePlaybackSnapshot(
            to: snapshotURL
        )

        #expect(snapshot.segmentCount == 1)
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
        let recordedPlaylist = try String(
            contentsOf: snapshot.playlistURL,
            encoding: .utf8
        )
        #expect(recordedPlaylist.contains("#EXT-X-ENDLIST"))
        #expect(!recordedPlaylist.contains("http://"))
        #expect(!recordedPlaylist.contains("https://"))

        let asset = try await HLSLocalPlaybackAsset(
            source: snapshot.playbackSource
        )
        let item = AVPlayerItem(asset: asset.urlAsset)
        let player = AVPlayer(playerItem: item)
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
            asset.close()
        }

        player.play()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline,
            item.status != .failed,
            player.currentTime().seconds <= 0.1
        {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(item.error == nil)
        #expect(player.currentTime().seconds > 0.1)
        let finalReceipt = try await recording.stopAndCommit()
        #expect(finalReceipt.segmentCount >= snapshot.segmentCount)
        #expect(
            FileManager.default.fileExists(atPath: snapshot.playlistURL.path)
        )
    }
}
#endif
