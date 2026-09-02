import AVFoundation
import Foundation

/// One playback metric and its zero-based delivery sequence.
public struct HLSPlaybackMetricDelivery: Equatable, Sendable {
    /// The event's position in this independent metric subscription.
    ///
    /// The first native event is `0`. A higher first value or a gap after a
    /// previous delivery reports events discarded by the bounded stream.
    public let sequenceNumber: UInt64

    /// The URL-free playback metric.
    public let event: HLSPlaybackMetricEvent

    init(
        sequenceNumber: UInt64,
        event: HLSPlaybackMetricEvent
    ) {
        self.sequenceNumber = sequenceNumber
        self.event = event
    }

    /// Returns events discarded before this delivery in the same stream.
    ///
    /// Pass `nil` for the first observed delivery. Deliveries from different
    /// calls to ``HLSPlaybackMetrics/sequencedEvents()`` are not comparable.
    public func droppedEventCount(
        after previous: HLSPlaybackMetricDelivery?
    ) -> UInt64 {
        droppedEventCount(
            afterSequenceNumber: previous?.sequenceNumber
        )
    }

    func droppedEventCount(
        afterSequenceNumber previous: UInt64?
    ) -> UInt64 {
        guard let previous else {
            return sequenceNumber
        }
        guard sequenceNumber > previous else {
            return 0
        }
        return sequenceNumber - previous - 1
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
extension HLSPlaybackMetrics {
    /// Starts a metric stream whose sequence gaps expose buffer pressure.
    ///
    /// This maps the same URL-free events as ``events()``. Sequence numbers
    /// start at zero for each call and are assigned before the bounded newest-
    /// event buffer, so consumers can detect discarded older events without
    /// requiring an unbounded diagnostic channel.
    public func sequencedEvents()
        -> AsyncThrowingStream<HLSPlaybackMetricDelivery, Error>
    {
        makeEventStream(initialState: HLSPlaybackMetricSequencer()) {
            sequencer,
            metric in
            sequencer.wrap(HLSPlaybackMetricMapper.map(metric))
        }
    }
}

struct HLSPlaybackMetricSequencer: Sendable {
    private var nextSequenceNumber: UInt64 = 0

    mutating func wrap(
        _ event: HLSPlaybackMetricEvent
    ) -> HLSPlaybackMetricDelivery {
        let delivery = HLSPlaybackMetricDelivery(
            sequenceNumber: nextSequenceNumber,
            event: event
        )
        if nextSequenceNumber < .max {
            nextSequenceNumber += 1
        }
        return delivery
    }
}
