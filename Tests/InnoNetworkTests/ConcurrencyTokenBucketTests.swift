import Foundation
import Testing

@testable import InnoNetwork

@Suite
struct ConcurrencyTokenBucketTests {
    @Test
    func acquireSucceedsImmediatelyUnderCapacity() async throws {
        let bucket = ConcurrencyTokenBucket(maxConcurrent: 2)

        try await bucket.acquire()
        try await bucket.acquire()

        let available = await bucket.available
        #expect(available == 0)
    }

    @Test
    func releaseRefillsAvailableTokens() async throws {
        let bucket = ConcurrencyTokenBucket(maxConcurrent: 1)
        try await bucket.acquire()
        let before = await bucket.available
        await bucket.release()
        let after = await bucket.available

        #expect(before == 0)
        #expect(after == 1)
    }

    @Test
    func releaseDoesNotExceedMaxConcurrent() async {
        let bucket = ConcurrencyTokenBucket(maxConcurrent: 2)

        await bucket.release()
        await bucket.release()
        await bucket.release()

        let available = await bucket.available
        #expect(available == 2)
    }

    @Test
    func waitersResumeFifoOnRelease() async throws {
        let bucket = ConcurrencyTokenBucket(maxConcurrent: 1)
        try await bucket.acquire()

        let order = OrderRecorder()
        async let first: Void = {
            try await bucket.acquire()
            await order.append(1)
        }()
        await waitForQueuedWaiters(1, in: bucket)
        #expect(await bucket.queuedWaitersCount == 1)

        async let second: Void = {
            try await bucket.acquire()
            await order.append(2)
        }()
        await waitForQueuedWaiters(2, in: bucket)
        #expect(await bucket.queuedWaitersCount == 2)

        await bucket.release()
        try? await Task.sleep(for: .milliseconds(20))
        await bucket.release()

        _ = try await (first, second)

        let recorded = await order.values
        #expect(recorded == [1, 2])
    }

    @Test
    func clampsMaxConcurrentToOne() async throws {
        let bucket = ConcurrencyTokenBucket(maxConcurrent: 0)

        let cap = await bucket.maxConcurrent
        #expect(cap == 1)

        try await bucket.acquire()
        let available = await bucket.available
        #expect(available == 0)
    }

    @Test
    func cancellationRemovesQueuedWaiterWithoutConsumingToken() async throws {
        let bucket = ConcurrencyTokenBucket(maxConcurrent: 1)
        try await bucket.acquire()

        let waiter = Task {
            try await bucket.acquire()
        }
        await waitForQueuedWaiters(1, in: bucket)
        #expect(await bucket.queuedWaitersCount == 1)

        waiter.cancel()
        do {
            try await waiter.value
            Issue.record("Expected queued acquire to throw CancellationError")
        } catch is CancellationError {
        }

        #expect(await bucket.queuedWaitersCount == 0)
        await bucket.release()
        #expect(await bucket.available == 1)
    }

    @Test
    func cancelledWaiterDoesNotConsumeReleaseBeforeCleanupHop() async throws {
        for _ in 0..<50 {
            let bucket = ConcurrencyTokenBucket(maxConcurrent: 1)
            try await bucket.acquire()

            let cancelled = Task {
                try await bucket.acquire()
            }
            await waitForQueuedWaiters(1, in: bucket)

            let follower = Task {
                try await bucket.acquire()
            }
            await waitForQueuedWaiters(2, in: bucket)

            cancelled.cancel()
            await bucket.release()

            do {
                try await cancelled.value
                Issue.record("Expected cancelled waiter to throw CancellationError")
            } catch is CancellationError {
            }

            try await follower.value
            await bucket.release()
            #expect(await bucket.available == 1)
            #expect(await bucket.queuedWaitersCount == 0)
        }
    }
}

private actor OrderRecorder {
    private(set) var values: [Int] = []
    func append(_ value: Int) {
        values.append(value)
    }
}

private func waitForQueuedWaiters(
    _ expectedCount: Int,
    in bucket: ConcurrencyTokenBucket
) async {
    for _ in 0..<100 {
        if await bucket.queuedWaitersCount >= expectedCount {
            return
        }
        await Task.yield()
    }
}
