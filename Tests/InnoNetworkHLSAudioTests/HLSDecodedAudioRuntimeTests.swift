#if compiler(>=6.4) && canImport(AVFoundation) && (os(macOS) || os(iOS))
import AVFoundation
import CoreAudioTypes
import CoreMedia
import Foundation
import Synchronization
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
        let maximumLeadTime: TimeInterval = 0.1
        let samples = output.pacedSamples(
            configuration: HLSDecodedAudioPacingConfiguration(
                maximumLeadTime: maximumLeadTime,
                pollingInterval: 0.005
            )
        )
        defer {
            player.pause()
            output.detach()
            player.replaceCurrentItem(with: nil)
        }

        player.play()
        var decodedSamples: [HLSDecodedAudioSample] = []
        for try await sample in samples {
            guard !sample.isMarkerOnly else {
                continue
            }
            let sampleTime = sample.outputPresentationTime.seconds
            let playerTime = playerItem.currentTime().seconds
            #expect(sampleTime.isFinite)
            #expect(playerTime.isFinite)
            #expect(sampleTime - playerTime <= maximumLeadTime + 0.05)
            decodedSamples.append(sample)
            if decodedSamples.count == 8 {
                break
            }
        }
        let sample = try #require(decodedSamples.first)

        #expect(decodedSamples.count == 8)
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

@Suite("HLS audio-mix processing runtime")
struct HLSAudioMixProcessingRuntimeTests {
    @Test(
        "AVPlayer processes the complete HLS audio mix in place",
        .timeLimit(.minutes(1))
    )
    @available(macOS 27, iOS 27, *)
    @MainActor
    func avPlayerProcessesAudioMix() async throws {
        guard
            let rawURL = ProcessInfo.processInfo.environment[
                "INNONETWORK_HLS_RUNTIME_PLAYLIST_URL"
            ],
            let playlistURL = URL(string: rawURL)
        else {
            try Test.cancel()
        }

        let prepared = Atomic<Bool>(false)
        let formatIsValid = Atomic<Bool>(false)
        let processedFrameCount = Atomic<Int>(0)
        let playerItem = AVPlayerItem(url: playlistURL)
        let tap = try HLSAudioMixProcessingTap(
            playerItem: playerItem,
            preferredFormat: try .float32(
                sampleRate: 48_000,
                channelCount: 1,
                interleaved: false
            ),
            callbacks: HLSAudioMixProcessingCallbacks(
                prepare: { context in
                    formatIsValid.store(
                        context.maximumFrameCount > 0
                            && context.processingFormat.mFormatID
                                == kAudioFormatLinearPCM
                            && context.processingFormat.mSampleRate
                                == 48_000
                            && context.processingFormat.mChannelsPerFrame
                                == 1,
                        ordering: .relaxed
                    )
                    prepared.store(true, ordering: .releasing)
                },
                process: { buffers, context in
                    if context.frameCount > 0,
                        buffers.first?.mData != nil,
                        context.timeRange.start.isNumeric
                    {
                        processedFrameCount.wrappingAdd(
                            context.frameCount,
                            ordering: .relaxed
                        )
                    }
                }
            )
        )
        let player = AVPlayer(playerItem: playerItem)
        defer {
            player.pause()
            tap.detach()
            player.replaceCurrentItem(with: nil)
        }

        player.play()
        for _ in 0..<500 {
            if processedFrameCount.load(ordering: .acquiring) > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let didPrepare = prepared.load(ordering: .acquiring)
        let receivedValidFormat = formatIsValid.load(ordering: .relaxed)
        let frameCount = processedFrameCount.load(ordering: .acquiring)
        #expect(didPrepare)
        #expect(receivedValidFormat)
        #expect(frameCount > 0)
    }
}
#endif
