import AVFoundation
import Foundation
import os

private final class HLSTimedMetadataDropCounter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    func add(_ value: Int) {
        count.withLock {
            $0 += max(0, value)
        }
    }

    func take() -> Int {
        count.withLock { count in
            let pending = count
            count = 0
            return pending
        }
    }
}

final class HLSTimedMetadataDelegate:
    NSObject,
    AVPlayerItemMetadataOutputPushDelegate
{
    private enum Input {
        case groups(
            [AVTimedMetadataGroup],
            source: HLSTimedMetadataSource
        )
        case sequenceFlushed
    }

    let queue = DispatchQueue(
        label: "com.innosquad.InnoNetwork.HLSTimedMetadata"
    )

    private let inputContinuation: AsyncStream<Input>.Continuation
    private let processingTask: Task<Void, Never>
    private let eventHub: HLSTimedMetadataEventHub
    private let dropCounter: HLSTimedMetadataDropCounter

    init(
        configuration: HLSTimedMetadataConfiguration,
        eventHub: HLSTimedMetadataEventHub,
        beforeProcessing: @escaping @Sendable () async -> Void = {}
    ) {
        let (inputs, inputContinuation) =
            AsyncStream<Input>.makeStream(
                bufferingPolicy: .bufferingNewest(
                    configuration.maximumBufferedEventCount
                )
            )
        self.inputContinuation = inputContinuation
        self.eventHub = eventHub
        let dropCounter = HLSTimedMetadataDropCounter()
        self.dropCounter = dropCounter
        self.processingTask = Task {
            await beforeProcessing()
            for await input in inputs {
                guard !Task.isCancelled else {
                    break
                }
                let droppedCount = dropCounter.take()
                if droppedCount > 0 {
                    eventHub.send(
                        .eventsDropped(count: droppedCount)
                    )
                }
                switch input {
                case .groups(let groups, let source):
                    let events = await HLSTimedMetadataMapper.map(
                        groups,
                        source: source,
                        configuration: configuration
                    )
                    for event in events {
                        eventHub.send(event)
                    }
                case .sequenceFlushed:
                    eventHub.send(.sequenceFlushed)
                }
            }
        }
        super.init()
    }

    func metadataOutput(
        _ output: AVPlayerItemMetadataOutput,
        didOutputTimedMetadataGroups groups:
            sending [AVTimedMetadataGroup],
        from playerItemTrack: AVPlayerItemTrack?
    ) {
        recordDrop(
            inputContinuation.yield(
                .groups(
                    groups,
                    source: playerItemTrack == nil ? .asset : .track
                )
            )
        )
    }

    func outputSequenceWasFlushed(
        _ output: AVPlayerItemOutput
    ) {
        recordDrop(
            inputContinuation.yield(.sequenceFlushed)
        )
    }

    func finish() {
        inputContinuation.finish()
        processingTask.cancel()
        eventHub.finish()
    }

    private func recordDrop(
        _ result: AsyncStream<Input>.Continuation.YieldResult
    ) {
        guard case .dropped(let input) = result else {
            return
        }
        switch input {
        case .groups(let groups, _):
            dropCounter.add(groups.count)
        case .sequenceFlushed:
            dropCounter.add(1)
        }
    }
}
