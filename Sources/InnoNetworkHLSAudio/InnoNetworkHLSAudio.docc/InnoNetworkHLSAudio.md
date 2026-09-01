# ``InnoNetworkHLSAudio``

Read decoded PCM from a caller-owned HLS player item without adding audio
processing responsibility to the core networking or playback products.

## Overview

``HLSDecodedAudioOutput`` is a narrow Xcode 27 companion around
`AVPlayerItemSampleBufferOutput`. It attaches one system output to an existing
HLS `AVPlayerItem`, preserves Core Media's typed `Sendable` sample buffer, and
allows only one outstanding read.

```swift
let configuration = try HLSDecodedAudioConfiguration.float32(
    sampleRate: 48_000,
    channelCount: 2
)
let decodedAudio = HLSDecodedAudioOutput(
    playerItem: playerItem,
    configuration: configuration
)

for try await sample in decodedAudio.pacedSamples(
    configuration: HLSDecodedAudioPacingConfiguration(
        maximumLeadTime: 0.25
    )
) {
    if sample.isMarkerOnly {
        continue
    }

    processPCM(
        sample.sampleBuffer,
        sequenceWasRestarted: sample.sequenceWasRestarted
    )
}

decodedAudio.detach()
```

The convenience configuration requests non-interleaved Float32 PCM by
default. A caller that already owns a specific linear PCM
`CMAudioFormatDescription` can pass it to
``HLSDecodedAudioConfiguration/init(requestedAudioFormat:)``. AVFoundation may
still vary the delivered numeric representation, sample size, or interleaving,
so processors must inspect the format description on each sample buffer and
perform any required conversion with `AudioConverter` or `AVAudioEngine`.

The output remains demand-driven rather than an automatically drained
`AsyncStream`. Direct consumers can continue to call
``HLSDecodedAudioOutput/nextSample()`` and own their pacing policy. The optional
``HLSDecodedAudioPacedSequence`` never prefetches: before starting another
AVFoundation read, it waits until the previously delivered sample boundary is
within ``HLSDecodedAudioPacingConfiguration/maximumLeadTime`` of the player
item's current time. A paused item therefore stops new reads once the lead is
filled. A backward time jump clears the previous boundary so a seek can deliver
the sequence-restart marker. The bounded polling interval is cancellation-safe.

The paced sequence retains but does not detach its output. Only one iterator or
direct read should consume at a time;
``HLSDecodedAudioError/readAlreadyInProgress`` rejects overlapping reads.
Pacing limits library read admission, not how many buffers the application
retains after delivery.

Marker-only buffers are retained with a zero ``HLSDecodedAudioSample/sampleCount``.
Skip their PCM processing while using
``HLSDecodedAudioSample/sequenceWasRestarted`` to reset application-owned
analysis state after a seek or sequence restart.

## Process the complete audio mix

On version 27 macOS, iOS, tvOS, and visionOS,
``HLSAudioMixProcessingTap`` can modify the complete audio mix in place. The
initializer rejects an existing application audio mix instead of overwriting
it. MediaToolbox treats the preferred format as a request, so use the format
delivered to the preparation callback as authoritative.

```swift
let tap = try HLSAudioMixProcessingTap(
    playerItem: playerItem,
    preferredFormat: try .float32(),
    position: .postEffects,
    callbacks: HLSAudioMixProcessingCallbacks(
        prepare: { context in
            prepareProcessor(
                maximumFrameCount: context.maximumFrameCount,
                format: context.processingFormat
            )
        },
        unprepare: {
            resetProcessor()
        },
        process: { buffers, context in
            processInPlace(
                buffers,
                frameCount: context.frameCount,
                format: context.processingFormat
            )
        }
    )
)

tap.detach()
```

The processing callback runs on a real-time audio thread. It must not allocate,
block, perform I/O, acquire contended locks, escape the supplied pointers, or
change the frame count and buffer layout. Preparation and unpreparation may be
paired more than once. Detachment is idempotent and removes only this tap's
mix, preserving a replacement installed by the application. watchOS has no
full-mix system API, and Apple does not supply FairPlay-protected audio to the
tap.

Playback, player lifetime, audio conversion, waveform storage, speech
recognition, and accessibility UI remain application responsibilities. The
bridge is not a DRM bypass and does not promise decoded samples for protected
audio. It supports only the HLS and decoded-PCM capability exposed by
AVFoundation on macOS 27, iOS 27, tvOS 27, watchOS 27, and visionOS 27.

## Topics

### Configure output

- ``HLSDecodedAudioConfiguration``
- ``HLSDecodedAudioError``

### Consume samples

- ``HLSDecodedAudioOutput``
- ``HLSDecodedAudioSample``
- ``HLSDecodedAudioPacingConfiguration``
- ``HLSDecodedAudioPacedSequence``

### Process a complete mix

- ``HLSAudioMixProcessingTap``
- ``HLSAudioMixProcessingCallbacks``
- ``HLSAudioMixProcessingContext``
- ``HLSAudioMixPreparationContext``
- ``HLSAudioMixProcessingPosition``
- ``HLSAudioMixStreamFlags``
- ``HLSAudioMixProcessingError``
