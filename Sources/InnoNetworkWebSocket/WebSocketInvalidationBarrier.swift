import Foundation

/// One-shot completion barrier used by ``WebSocketManager/shutdown()``.
///
/// The manager keeps one instance for the URLSession invalidation callback and
/// another for the full delegate-drain/task-cleanup boundary. A barrier is open
/// after ``complete()`` is called once; subsequent ``wait()`` calls return
/// immediately. Concurrent waiters are resumed in arbitrary order.
actor WebSocketInvalidationBarrier {
    private var isCompleted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isCompleted else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func complete() {
        guard !isCompleted else { return }
        isCompleted = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll(keepingCapacity: false)
    }
}
