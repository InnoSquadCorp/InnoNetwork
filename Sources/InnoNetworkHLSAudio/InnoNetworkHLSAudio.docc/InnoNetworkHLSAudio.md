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

while let sample = try await decodedAudio.nextSample() {
    if sample.isMarkerOnly {
        continue
    }

    processPCM(
        sample.sampleBuffer,
        sequenceWasRestarted: sample.sequenceWasRestarted
    )

    // Stop requesting more buffers when output is sufficiently ahead of the
    // player item's timebase. The appropriate lead is application-specific.
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

The output is deliberately demand-driven rather than an automatically drained
`AsyncStream`. AVFoundation can decode far ahead of presentation; applications
must compare ``HLSDecodedAudioSample/outputPresentationTime`` with the player
item's timebase and pause reads after preparing enough near-future audio.
``HLSDecodedAudioError/readAlreadyInProgress`` rejects competing consumers so
sample order has one owner.

Marker-only buffers are retained with a zero ``HLSDecodedAudioSample/sampleCount``.
Skip their PCM processing while using
``HLSDecodedAudioSample/sequenceWasRestarted`` to reset application-owned
analysis state after a seek or sequence restart.

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
