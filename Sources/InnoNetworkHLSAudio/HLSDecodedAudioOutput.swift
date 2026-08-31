import AVFoundation

/// Demand-driven decoded PCM access for one caller-owned HLS player item.
///
/// The output allows only one outstanding read. It does not buffer samples,
/// create a player, or advance playback. The caller remains responsible for
/// comparing output timestamps with the player item's timebase and pausing
/// reads that run too far ahead of presentation.
@available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)
@MainActor
public final class HLSDecodedAudioOutput {
    package let playerItem: AVPlayerItem
    package let output: AVPlayerItemSampleBufferOutput

    private var readIsInProgress = false

    /// Whether the system output is attached to the player item.
    public private(set) var isAttached = true

    /// Creates and attaches a decoded-audio output to a player item.
    ///
    /// The player item must represent HLS media. Playback only produces audio
    /// while the item is current on an `AVPlayer`.
    public init(
        playerItem: AVPlayerItem,
        configuration: HLSDecodedAudioConfiguration
    ) {
        self.playerItem = playerItem

        let systemConfiguration =
            AVPlayerItemSampleBufferOutputAudioConfiguration()
        systemConfiguration.requestedAudioFormat =
            configuration.requestedAudioFormat
        let output = AVPlayerItemSampleBufferOutput(
            configuration: systemConfiguration
        )
        self.output = output
        playerItem.add(output)
    }

    deinit {
        if isAttached {
            playerItem.remove(output)
        }
    }

    /// Waits for and returns the next sample buffer.
    ///
    /// Cancellation is reported as `CancellationError`. A `nil` result means
    /// AVFoundation ended the sequence. Marker-only buffers are preserved so
    /// clients can observe timeline discontinuities and skip them explicitly.
    public func nextSample() async throws -> HLSDecodedAudioSample? {
        guard isAttached else {
            throw HLSDecodedAudioError.outputDetached
        }
        guard !readIsInProgress else {
            throw HLSDecodedAudioError.readAlreadyInProgress
        }

        readIsInProgress = true
        defer { readIsInProgress = false }

        try Task.checkCancellation()
        let value = await output.nextSampleBuffer()
        try Task.checkCancellation()
        guard isAttached else {
            throw HLSDecodedAudioError.outputDetached
        }
        return value.map(HLSDecodedAudioSample.init)
    }

    /// Returns the next sample immediately when one is already available.
    ///
    /// A `nil` result means no sample is currently available. Use
    /// ``nextSample()`` when waiting is preferable to polling.
    public func nextAvailableSample() throws(HLSDecodedAudioError) -> HLSDecodedAudioSample? {
        guard isAttached else {
            throw .outputDetached
        }
        guard !readIsInProgress else {
            throw .readAlreadyInProgress
        }
        return output.nextAvailableSampleBuffer().map(HLSDecodedAudioSample.init)
    }

    /// Detaches the system output from the player item.
    ///
    /// Detachment is idempotent and terminal. Create a new output to resume
    /// decoded-audio delivery.
    public func detach() {
        guard isAttached else { return }
        playerItem.remove(output)
        isAttached = false
    }
}
