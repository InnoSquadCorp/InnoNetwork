import AVFoundation
import CoreMedia
import Foundation

/// A non-prefetching sequence of paced decoded PCM samples.
///
/// The sequence starts an AVFoundation read only after the previously
/// delivered sample is within the configured lead of the player item's
/// current time. It retains the output but does not detach it when iteration
/// ends. Overlapping iterator or direct reads are rejected by the output's
/// existing one-outstanding-read contract; callers must designate one logical
/// consumer to preserve sample order.
@available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)
public struct HLSDecodedAudioPacedSequence: AsyncSequence, Sendable {
    public typealias Element = HLSDecodedAudioSample

    private let output: HLSDecodedAudioOutput
    private let configuration: HLSDecodedAudioPacingConfiguration

    package init(
        output: HLSDecodedAudioOutput,
        configuration: HLSDecodedAudioPacingConfiguration
    ) {
        self.output = output
        self.configuration = configuration
    }

    /// Creates an iterator over the same one-read-at-a-time output.
    public func makeAsyncIterator() -> Iterator {
        Iterator(
            output: output,
            configuration: configuration
        )
    }

    /// Iterator state for one paced sample consumer.
    public struct Iterator: AsyncIteratorProtocol {
        private let output: HLSDecodedAudioOutput
        private let configuration: HLSDecodedAudioPacingConfiguration
        private var pacingState = HLSDecodedAudioPacingState()
        private var isFinished = false

        package init(
            output: HLSDecodedAudioOutput,
            configuration: HLSDecodedAudioPacingConfiguration,
            pacingState: HLSDecodedAudioPacingState = .init()
        ) {
            self.output = output
            self.configuration = configuration
            self.pacingState = pacingState
        }

        /// Waits for the pacing window, then requests exactly one sample.
        public nonisolated(nonsending) mutating func next() async throws
            -> HLSDecodedAudioSample?
        {
            guard !isFinished else {
                return nil
            }
            try await waitUntilReadIsAdmitted()
            try Task.checkCancellation()
            guard let sample = try await output.nextSample() else {
                isFinished = true
                return nil
            }
            pacingState.record(sample)
            return sample
        }

        private nonisolated(nonsending) mutating func waitUntilReadIsAdmitted()
            async throws
        {
            while true {
                try Task.checkCancellation()
                let itemTime = try await output.pacingItemTime()
                if pacingState.admitsRead(
                    itemTime: itemTime,
                    maximumLeadTime: configuration.maximumLeadTime
                ) {
                    return
                }
                try await ContinuousClock().sleep(
                    for: .seconds(configuration.pollingInterval)
                )
            }
        }
    }
}

@available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)
package struct HLSDecodedAudioPacingState: Sendable {
    private var deliveredBoundary: CMTime?
    private var lastObservedItemTime: CMTime?

    package mutating func admitsRead(
        itemTime: CMTime,
        maximumLeadTime: TimeInterval
    ) -> Bool {
        guard itemTime.isNumeric else {
            lastObservedItemTime = nil
            return true
        }
        if let lastObservedItemTime,
            lastObservedItemTime.isNumeric,
            CMTimeCompare(itemTime, lastObservedItemTime) < 0
        {
            deliveredBoundary = nil
        }
        self.lastObservedItemTime = itemTime
        guard let deliveredBoundary,
            deliveredBoundary.isNumeric
        else {
            return true
        }
        let lead = CMTime(
            seconds: maximumLeadTime,
            preferredTimescale: 1_000_000
        )
        let readHorizon = CMTimeAdd(itemTime, lead)
        guard readHorizon.isNumeric else {
            return true
        }
        return CMTimeCompare(deliveredBoundary, readHorizon) <= 0
    }

    package mutating func record(_ sample: HLSDecodedAudioSample) {
        let start =
            sample.outputPresentationTime.isNumeric
            ? sample.outputPresentationTime
            : sample.presentationTime
        record(start: start, duration: sample.duration)
    }

    package mutating func record(
        start: CMTime,
        duration: CMTime
    ) {
        guard start.isNumeric else {
            deliveredBoundary = nil
            return
        }
        guard duration.isNumeric,
            CMTimeCompare(duration, .zero) > 0
        else {
            deliveredBoundary = start
            return
        }
        let boundary = CMTimeAdd(start, duration)
        deliveredBoundary = boundary.isNumeric ? boundary : start
    }
}
