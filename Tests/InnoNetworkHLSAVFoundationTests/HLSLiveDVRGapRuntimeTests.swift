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
@Suite("HLS live DVR GAP runtime", .serialized)
struct HLSLiveDVRGapRuntimeTests {
    @Test(
        "recorded GAP skips unavailable media in AVPlayer",
        .timeLimit(.minutes(1))
    )
    func recordsAndPlaysPastGap() async throws {
        guard
            let rawURL = ProcessInfo.processInfo.environment[
                "INNONETWORK_HLS_LIVE_GAP_RUNTIME_URL"
            ],
            let playlistURL = URL(string: rawURL)
        else {
            try Test.cancel()
        }

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "innonetwork-live-gap-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: destinationURL)
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
        let receipt = try await HLSLiveDVRRecorder(
            client: client,
            configuration: .advanced(startPosition: .currentWindow)
        ).record(from: playlistURL, to: destinationURL)

        #expect(receipt.segmentCount == 3)
        #expect(receipt.gapCount == 1)
        #expect(
            !FileManager.default.fileExists(
                atPath: receipt.directoryURL
                    .appendingPathComponent(
                        "resources/gap-00001.m4s"
                    ).path
            )
        )
        let recordedPlaylist = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        #expect(
            recordedPlaylist.contains(
                "#EXT-X-GAP\n#EXTINF:1.002667,\nresources/gap-00001.m4s"
            )
        )
        #expect(!recordedPlaylist.contains("http://"))
        #expect(!recordedPlaylist.contains("https://"))

        let asset = try await HLSLocalPlaybackAsset(
            source: receipt.playbackSource
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
            player.currentTime().seconds <= 1.9
        {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(item.error == nil)
        #expect(player.currentTime().seconds > 1.9)
    }
}
#endif
