import Testing

@testable import InnoNetwork

private actor StreamingBackpressureProbe {
    enum Phase: Hashable, Sendable {
        case started(Int)
        case completed(Int)
    }

    private var phases: Set<Phase> = []
    private var waiters: [Phase: [CheckedContinuation<Void, Never>]] = [:]

    func mark(_ phase: Phase) {
        phases.insert(phase)
        let continuations = waiters.removeValue(forKey: phase) ?? []
        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait(for phase: Phase) async {
        guard !phases.contains(phase) else { return }
        await withCheckedContinuation { continuation in
            waiters[phase, default: []].append(continuation)
        }
    }

    func contains(_ phase: Phase) -> Bool {
        phases.contains(phase)
    }
}

@Suite("StreamingOutputSequence backpressure")
struct StreamingOutputSequenceTests {
    @Test("Lossless delivery suspends the producer until each output is consumed")
    func losslessDeliverySuspendsProducer() async throws {
        let (sequence, sink) = StreamingOutputSequence<Int>.make(buffering: .backpressured)
        let probe = StreamingBackpressureProbe()

        let producer = Task {
            await probe.mark(.started(1))
            try await sink.yield(1)
            await probe.mark(.completed(1))

            await probe.mark(.started(2))
            try await sink.yield(2)
            await probe.mark(.completed(2))
            sink.finish()
        }

        await probe.wait(for: .started(1))
        #expect(!(await probe.contains(.completed(1))))

        var iterator = sequence.makeAsyncIterator()
        #expect(try await iterator.next() == 1)

        await probe.wait(for: .completed(1))
        await probe.wait(for: .started(2))
        #expect(!(await probe.contains(.completed(2))))

        #expect(try await iterator.next() == 2)
        try await producer.value
        #expect(try await iterator.next() == nil)
    }

    @Test("Cancelling a suspended producer releases the acknowledgement wait")
    func cancellationReleasesSuspendedProducer() async {
        let (_, sink) = StreamingOutputSequence<Int>.make(buffering: .backpressured)
        let probe = StreamingBackpressureProbe()

        let producer = Task { () -> NetworkError? in
            await probe.mark(.started(1))
            do {
                try await sink.yield(1)
                return nil
            } catch let error as NetworkError {
                return error
            } catch {
                Issue.record("Expected NetworkError, got \(error)")
                return nil
            }
        }

        await probe.wait(for: .started(1))
        producer.cancel()

        guard let error = await producer.value else {
            Issue.record("Expected cancellation to terminate the suspended producer")
            return
        }
        guard case .cancelled = error else {
            Issue.record("Expected NetworkError.cancelled, got \(error)")
            return
        }
    }
}
