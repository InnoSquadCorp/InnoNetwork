import Foundation
import Testing

@testable import InnoNetwork

private actor GatedCountingExporter: NetworkSpanExporting {
    private var entered = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var count = 0
    private(set) var maximumBatch = 0

    func export(_ spans: [NetworkSpan]) async {
        entered = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        count += spans.count
        maximumBatch = max(maximumBatch, spans.count)
    }

    func waitForExport() async {
        if !entered { await withCheckedContinuation { startWaiters.append($0) } }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@Suite("Streaming resource soak", .serialized, .timeLimit(.minutes(3)))
struct StreamingResourceSoakTests {
    private func duration() throws -> Duration {
        let seconds = Int(ProcessInfo.processInfo.environment["INNO_STREAM_SOAK_SECONDS"] ?? "0") ?? -1
        try #require((0...120).contains(seconds))
        return .seconds(seconds)
    }

    @Test("a blocked exporter cannot retain an unbounded reconnect history")
    func blockedExporterAndReconnects() async throws {
        let duration = try duration()
        let exporter = GatedCountingExporter()
        let observer = NetworkSpanObserver(exporter: exporter, policy: .init(maximumBufferedSpans: 32, batchSize: 8))
        let requestID = UUID()
        await observer.handle(.requestStart(requestID: requestID, method: "GET", url: "", retryIndex: 0))
        await observer.handle(
            .decision(
                .init(requestID: requestID, attemptIndex: 0, kind: .dispatch, outcome: .allowed, reason: .policyAllowed)
            ))
        await observer.handle(.retryScheduled(requestID: requestID, retryIndex: 0, delay: 0, reason: "fixture"))
        await exporter.waitForExport()
        let clock = ContinuousClock()
        let started = clock.now
        var attempts = 1
        repeat {
            await observer.handle(
                .decision(
                    .init(
                        requestID: requestID, attemptIndex: attempts, kind: .dispatch, outcome: .allowed,
                        reason: .policyAllowed)))
            await observer.handle(
                .retryScheduled(requestID: requestID, retryIndex: attempts, delay: 0, reason: "fixture"))
            attempts += 1
            if attempts.isMultiple(of: 1000) {
                #expect(await observer.retainedRequestCount == 1)
                #expect(await observer.retainedAttemptCount == 0)
                #expect(await observer.bufferedSpanCount <= 32)
            }
        } while attempts < 1000 || started.duration(to: clock.now) < duration
        await observer.handle(.requestFailed(requestID: requestID, errorCode: -999, message: "cancelled"))
        #expect(await observer.retainedRequestCount == 0)
        #expect(await observer.retainedAttemptCount == 0)
        #expect(await observer.bufferedSpanCount == 32)
        await exporter.release()
        await observer.flush()
        #expect(await observer.bufferedSpanCount == 0)
        #expect(await exporter.maximumBatch <= 8)
        let exported = await exporter.count
        let dropped = await observer.droppedSpanCount
        #expect(exported + dropped == attempts + 1)
        print(
            "span soak: \(attempts) attempts, \(started.duration(to: clock.now)); exported + dropped exactly accounted")
    }

    @Test("sustained backpressured streaming preserves order and releases a cancelled producer")
    func sustainedStreaming() async throws {
        let duration = try duration()
        let (sequence, sink) = StreamingOutputSequence<Int>.make(buffering: .backpressured)
        let clock = ContinuousClock()
        let started = clock.now
        let producer = Task {
            var value = 0
            do {
                while true {
                    try await sink.yield(value)
                    value += 1
                }
            } catch let error as NetworkError {
                #expect(NetworkError.isCancellation(error))
            } catch {
                Issue.record("Unexpected producer error: \(error)")
            }
            sink.finish()
        }
        var iterator = sequence.makeAsyncIterator()
        var received = 0
        repeat {
            let next = try await iterator.next()
            #expect(next == received)
            received += 1
        } while received < 1000 || started.duration(to: clock.now) < duration
        producer.cancel()
        await producer.value
        // A single already enqueued delivery may remain after cancellation.
        var residual = 0
        while try await iterator.next() != nil { residual += 1 }
        #expect(residual <= 1)
        print("stream soak: \(received) ordered deliveries, \(started.duration(to: clock.now)); cancellation completed")
    }
}
