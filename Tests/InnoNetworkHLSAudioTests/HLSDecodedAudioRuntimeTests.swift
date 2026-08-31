#if canImport(AVFoundation) && (os(macOS) || os(iOS))
import AVFoundation
import CoreAudioTypes
import CoreMedia
import Foundation
import Testing

@testable import InnoNetworkHLSAudio

@Suite("Decoded HLS audio runtime")
struct HLSDecodedAudioRuntimeTests {
    @Test(
        "AVPlayer delivers decoded PCM from the loopback HLS fixture",
        .timeLimit(.minutes(1))
    )
    @available(macOS 27, iOS 27, *)
    @MainActor
    func avPlayerDeliversDecodedPCM() async throws {
        guard
            let rawURL = ProcessInfo.processInfo.environment[
                "INNONETWORK_HLS_RUNTIME_PLAYLIST_URL"
            ],
            let playlistURL = URL(string: rawURL)
        else {
            try Test.cancel()
        }

        let playerItem = AVPlayerItem(url: playlistURL)
        let output = HLSDecodedAudioOutput(
            playerItem: playerItem,
            configuration: try .float32(
                sampleRate: 48_000,
                channelCount: 1,
                interleaved: false
            )
        )
        let player = AVPlayer(playerItem: playerItem)
        defer {
            player.pause()
            output.detach()
            player.replaceCurrentItem(with: nil)
        }

        player.play()
        let sample = try #require(await output.nextSample())

        #expect(!sample.isMarkerOnly)
        #expect(sample.sampleCount > 0)
        #expect(sample.presentationTime.isNumeric)
        #expect(sample.outputPresentationTime.isNumeric)
        let streamDescription = sample.sampleBuffer.withUnsafeSampleBuffer {
            CMSampleBufferGetFormatDescription($0).flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            }
        }
        let decodedFormat = try #require(streamDescription)
        #expect(decodedFormat.mFormatID == kAudioFormatLinearPCM)
        #expect(decodedFormat.mSampleRate == 48_000)
        #expect(decodedFormat.mChannelsPerFrame == 1)
    }
}
#endif
