#if compiler(>=6.4)
import AVFoundation
import CoreMedia

/// One decoded PCM sample-buffer result from an HLS player item.
@available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)
public struct HLSDecodedAudioSample: Sendable {
    /// The typed, ready-to-use Core Media sample buffer.
    public let sampleBuffer: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>

    /// Whether AVFoundation restarted the output sequence before this buffer.
    public let sequenceWasRestarted: Bool

    /// The sample buffer's presentation timestamp.
    public let presentationTime: CMTime

    /// The presentation timestamp adjusted for output.
    public let outputPresentationTime: CMTime

    /// The sample buffer's duration.
    public let duration: CMTime

    /// The number of samples in the buffer.
    public let sampleCount: CMItemCount

    /// Whether this is a marker-only buffer with no PCM samples.
    public var isMarkerOnly: Bool {
        sampleCount == 0
    }

    package init(
        _ value: AVPlayerItemSampleBufferOutput.SampleBufferInSequence
    ) {
        let sampleBuffer = value.sampleBuffer
        self.sampleBuffer = sampleBuffer
        self.sequenceWasRestarted = value.sequenceWasRestarted
        self.presentationTime = sampleBuffer.presentationTimeStamp
        self.outputPresentationTime = sampleBuffer.outputPresentationTimeStamp
        self.duration = sampleBuffer.duration
        self.sampleCount = sampleBuffer.withUnsafeSampleBuffer {
            CMSampleBufferGetNumSamples($0)
        }
    }
}
#endif
