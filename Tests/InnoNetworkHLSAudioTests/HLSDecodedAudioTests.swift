#if compiler(>=6.4) && canImport(AVFoundation)
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

    @Test("Pacing configuration normalizes unsafe timing values")
    @available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)
    func pacingConfigurationBounds() {
        #expect(
            HLSDecodedAudioPacingConfiguration(
                maximumLeadTime: -.infinity,
                pollingInterval: .nan
            )
                == HLSDecodedAudioPacingConfiguration(
                    maximumLeadTime: 0.25,
                    pollingInterval: 0.01
                )
        )

        let minimum = HLSDecodedAudioPacingConfiguration(
            maximumLeadTime: -1,
            pollingInterval: 0
        )
        #expect(minimum.maximumLeadTime == 0)
        #expect(minimum.pollingInterval == 0.001)

        let maximum = HLSDecodedAudioPacingConfiguration(
            maximumLeadTime: 60,
            pollingInterval: 1
        )
        #expect(maximum.maximumLeadTime == 10)
        #expect(maximum.pollingInterval == 0.25)
    }

    @Test("Pacing admits one read window and resets after a backward seek")
    @available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)
    func pacingState() {
        var state = HLSDecodedAudioPacingState()
        let initiallyAdmitted = state.admitsRead(
            itemTime: CMTime(seconds: 0.7, preferredTimescale: 1_000),
            maximumLeadTime: 0.25
        )
        #expect(initiallyAdmitted)
        state.record(
            start: CMTime(seconds: 1, preferredTimescale: 1_000),
            duration: CMTime(seconds: 0.1, preferredTimescale: 1_000)
        )

        let heldAhead = state.admitsRead(
            itemTime: CMTime(seconds: 0.7, preferredTimescale: 1_000),
            maximumLeadTime: 0.25
        )
        #expect(!heldAhead)
        let admittedAtBoundary = state.admitsRead(
            itemTime: CMTime(seconds: 0.85, preferredTimescale: 1_000),
            maximumLeadTime: 0.25
        )
        #expect(admittedAtBoundary)

        let heldBeforeSeek = state.admitsRead(
            itemTime: CMTime(seconds: 0.9, preferredTimescale: 1_000),
            maximumLeadTime: 0
        )
        #expect(!heldBeforeSeek)
        let admittedAfterSeek = state.admitsRead(
            itemTime: CMTime(seconds: 0.2, preferredTimescale: 1_000),
            maximumLeadTime: 0
        )
        #expect(admittedAfterSeek)
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

    @Test("A paced iterator observes terminal output detachment")
    @available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)
    @MainActor
    func pacedOutputLifecycle() async throws {
        let sourceURL = try #require(
            URL(string: "https://example.com/live.m3u8")
        )
        let playerItem = AVPlayerItem(url: sourceURL)
        let output = HLSDecodedAudioOutput(
            playerItem: playerItem,
            configuration: try .float32()
        )
        var iterator = output.pacedSamples().makeAsyncIterator()

        output.detach()

        await #expect(throws: HLSDecodedAudioError.outputDetached) {
            _ = try await iterator.next()
        }
    }

    @Test("Cancellation interrupts a paced wait before another read")
    @available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)
    @MainActor
    func cancelledPacedWait() async throws {
        let sourceURL = try #require(
            URL(string: "https://example.com/live.m3u8")
        )
        let playerItem = AVPlayerItem(url: sourceURL)
        let output = HLSDecodedAudioOutput(
            playerItem: playerItem,
            configuration: try .float32()
        )
        defer { output.detach() }

        let read = Task { @MainActor in
            var pacingState = HLSDecodedAudioPacingState()
            pacingState.record(
                start: CMTime(seconds: 1, preferredTimescale: 1_000),
                duration: CMTime(seconds: 0.1, preferredTimescale: 1_000)
            )
            var iterator = HLSDecodedAudioPacedSequence.Iterator(
                output: output,
                configuration: HLSDecodedAudioPacingConfiguration(
                    maximumLeadTime: 0,
                    pollingInterval: 0.25
                ),
                pacingState: pacingState
            )
            return try await iterator.next()
        }
        await Task.yield()
        read.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await read.value
        }
    }

    @Test("Cancellation before a read reaches AVFoundation is preserved")
    @available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)
    @MainActor
    func cancelledRead() async throws {
        let sourceURL = try #require(
            URL(string: "https://example.com/live.m3u8")
        )
        let playerItem = AVPlayerItem(url: sourceURL)
        let output = HLSDecodedAudioOutput(
            playerItem: playerItem,
            configuration: try .float32()
        )
        defer { output.detach() }

        let read = Task {
            await Task.yield()
            return try await output.nextSample()
        }
        read.cancel()

        await #expect(throws: CancellationError.self) {
            try await read.value
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
