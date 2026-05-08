import Foundation
import Testing

@testable import InnoNetwork

@Suite
struct ConcurrencyTokenBucketTests {
    @Test
    func acquireSucceedsImmediatelyUnderCapacity() async {
        let bucket = ConcurrencyTokenBucket(maxConcurrent: 2)

        await bucket.acquire()
        await bucket.acquire()

        let available = await bucket.available
        #expect(available == 0)
    }

    @Test
    func releaseRefillsAvailableTokens() async {
        let bucket = ConcurrencyTokenBucket(maxConcurrent: 1)
        await bucket.acquire()
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
    func waitersResumeFifoOnRelease() async {
        let bucket = ConcurrencyTokenBucket(maxConcurrent: 1)
        await bucket.acquire()

        let order = OrderRecorder()
        async let first: Void = {
            await bucket.acquire()
            await order.append(1)
        }()
        await waitForQueuedWaiters(1, in: bucket)
        #expect(await bucket.queuedWaitersCount == 1)

        async let second: Void = {
            await bucket.acquire()
            await order.append(2)
        }()
        await waitForQueuedWaiters(2, in: bucket)
        #expect(await bucket.queuedWaitersCount == 2)

        await bucket.release()
        try? await Task.sleep(for: .milliseconds(20))
        await bucket.release()

        _ = await (first, second)

        let recorded = await order.values
        #expect(recorded == [1, 2])
    }

    @Test
    func clampsMaxConcurrentToOne() async {
        let bucket = ConcurrencyTokenBucket(maxConcurrent: 0)

        let cap = await bucket.maxConcurrent
        #expect(cap == 1)

        await bucket.acquire()
        let available = await bucket.available
        #expect(available == 0)
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
