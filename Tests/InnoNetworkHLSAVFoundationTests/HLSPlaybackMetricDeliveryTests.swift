#if canImport(AVFoundation)
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS playback metric delivery")
struct HLSPlaybackMetricDeliveryTests {
    @Test("sequencing starts at zero and advances per mapped event")
    func sequencingAdvances() {
        var sequencer = HLSPlaybackMetricSequencer()
        let event = HLSPlaybackMetricEvent.stalled(
            HLSPlaybackMetricContext(
                date: Date(timeIntervalSince1970: 1_000),
                mediaTime: 12
            )
        )

        let first = sequencer.wrap(event)
        let second = sequencer.wrap(event)

        #expect(first.sequenceNumber == 0)
        #expect(first.event == event)
        #expect(second.sequenceNumber == 1)
        #expect(second.droppedEventCount(after: first) == 0)
    }

    @Test("delivery gaps report initial and subsequent drops")
    func deliveryGapsReportDrops() {
        let event = HLSPlaybackMetricEvent.stalled(
            HLSPlaybackMetricContext(
                date: Date(timeIntervalSince1970: 1_000),
                mediaTime: nil
            )
        )
        let firstObserved = HLSPlaybackMetricDelivery(
            sequenceNumber: 3,
            event: event
        )
        let nextObserved = HLSPlaybackMetricDelivery(
            sequenceNumber: 8,
            event: event
        )

        #expect(firstObserved.droppedEventCount(after: nil) == 3)
        #expect(
            nextObserved.droppedEventCount(after: firstObserved) == 4
        )
        #expect(firstObserved.droppedEventCount(after: nextObserved) == 0)
    }

    @Test("newest-event buffering leaves an observable sequence gap")
    func newestEventBufferingLeavesObservableGap() async {
        let (stream, continuation) =
            AsyncStream<HLSPlaybackMetricDelivery>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
        var sequencer = HLSPlaybackMetricSequencer()
        let event = HLSPlaybackMetricEvent.stalled(
            HLSPlaybackMetricContext(
                date: Date(timeIntervalSince1970: 1_000),
                mediaTime: nil
            )
        )

        continuation.yield(sequencer.wrap(event))
        continuation.yield(sequencer.wrap(event))
        continuation.yield(sequencer.wrap(event))
        continuation.finish()

        var iterator = stream.makeAsyncIterator()
        let delivered = await iterator.next()
        #expect(delivered?.sequenceNumber == 2)
        #expect(delivered?.droppedEventCount(after: nil) == 2)
        #expect(await iterator.next() == nil)
    }
}
#endif
