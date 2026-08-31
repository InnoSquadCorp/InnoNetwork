#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import InnoNetworkHLSAudio

@Suite("Decoded HLS audio")
struct HLSDecodedAudioTests {
    @Test("Float32 configuration validates its dimensions")
    @available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)
    func float32ConfigurationValidation() throws {
        #expect(
            throws: HLSDecodedAudioError.invalidSampleRate
        ) {
            try HLSDecodedAudioConfiguration.float32(sampleRate: .nan)
        }
        #expect(
            throws: HLSDecodedAudioError.invalidSampleRate
        ) {
            try HLSDecodedAudioConfiguration.float32(sampleRate: 0)
        }
        #expect(
            throws: HLSDecodedAudioError.invalidChannelCount
        ) {
            try HLSDecodedAudioConfiguration.float32(channelCount: 0)
        }

        let configuration = try HLSDecodedAudioConfiguration.float32(
            sampleRate: 44_100,
            channelCount: 1,
            interleaved: true
        )
        #expect(
            HLSDecodedAudioConfiguration.isLinearPCM(
                configuration.requestedAudioFormat
            )
        )

        let videoFormat = try CMFormatDescription(
            videoCodecType: .h264,
            width: 16,
            height: 16
        )
        #expect(
            throws: HLSDecodedAudioError.requestedFormatMustBeLinearPCM
        ) {
            try HLSDecodedAudioConfiguration(
                requestedAudioFormat: videoFormat
            )
        }
    }

    @Test("Marker buffers preserve timeline and restart metadata")
    @available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)
    func markerBufferMapping() {
        let timestamp = CMTime(seconds: 3, preferredTimescale: 600)
        let duration = CMTime(seconds: 0.5, preferredTimescale: 600)
        let marker = CMReadySampleBuffer<Never>(
            markerAt: timestamp,
            duration: duration
        )
        let dynamic = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(
            marker
        )
        let value =
            AVPlayerItemSampleBufferOutput.SampleBufferInSequence(
                sampleBuffer: dynamic,
                sequenceWasRestarted: true
            )

        let sample = HLSDecodedAudioSample(value)

        #expect(sample.isMarkerOnly)
        #expect(sample.sampleCount == 0)
        #expect(sample.sequenceWasRestarted)
        #expect(sample.presentationTime == timestamp)
        #expect(sample.duration == duration)
    }

    @Test("PCM buffers preserve sample count and output time")
    @available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)
    func pcmBufferMapping() throws {
        let configuration = try HLSDecodedAudioConfiguration.float32(
            channelCount: 1,
            interleaved: true
        )
        let timestamp = CMTime(seconds: 2, preferredTimescale: 48_000)
        let pcm = CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>(
            audioDataBuffer: CMReadOnlyDataBlockBuffer(Data(count: 16)),
            formatDescription: configuration.requestedAudioFormat,
            sampleCount: 4,
            presentationTimeStamp: timestamp
        )
        let dynamic = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(pcm)
        let value =
            AVPlayerItemSampleBufferOutput.SampleBufferInSequence(
                sampleBuffer: dynamic,
                sequenceWasRestarted: false
            )

        let sample = HLSDecodedAudioSample(value)

        #expect(!sample.isMarkerOnly)
        #expect(sample.sampleCount == 4)
        #expect(!sample.sequenceWasRestarted)
        #expect(sample.presentationTime == timestamp)
        #expect(sample.outputPresentationTime == timestamp)
    }

    @Test("Output attachment has an idempotent terminal detach")
    @available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)
    @MainActor
    func outputLifecycle() throws {
        let sourceURL = try #require(
            URL(string: "https://example.com/live.m3u8")
        )
        let playerItem = AVPlayerItem(url: sourceURL)
        let originalOutputCount = playerItem.outputs.count
        let configuration = try HLSDecodedAudioConfiguration.float32()
        let output = HLSDecodedAudioOutput(
            playerItem: playerItem,
            configuration: configuration
        )

        #expect(output.isAttached)
        #expect(playerItem.outputs.count == originalOutputCount + 1)

        output.detach()
        output.detach()

        #expect(!output.isAttached)
        #expect(playerItem.outputs.count == originalOutputCount)
        #expect(throws: HLSDecodedAudioError.outputDetached) {
            try output.nextAvailableSample()
        }
    }

    @Test("Output removal follows wrapper lifetime")
    @available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)
    @MainActor
    func outputLifetime() throws {
        let sourceURL = try #require(
            URL(string: "https://example.com/live.m3u8")
        )
        let playerItem = AVPlayerItem(url: sourceURL)
        let originalOutputCount = playerItem.outputs.count
        var output: HLSDecodedAudioOutput? = HLSDecodedAudioOutput(
            playerItem: playerItem,
            configuration: try .float32()
        )
        weak let weakOutput = output

        #expect(playerItem.outputs.count == originalOutputCount + 1)
        output = nil

        #expect(weakOutput == nil)
        #expect(playerItem.outputs.count == originalOutputCount)
    }

    @Test("Errors provide actionable redacted messages")
    func localizedErrors() {
        let error = HLSDecodedAudioError.readAlreadyInProgress

        #expect(
            error.errorDescription
                == "Another decoded-audio read is already in progress."
        )
        #expect(
            error.recoverySuggestion
                == "Wait for or cancel the active read before starting another one."
        )
        #expect(String(describing: error) == "readAlreadyInProgress")
    }
}
#endif
