import Foundation

/// Barrier used by ``WebSocketManager/shutdown()`` to drain in-flight
/// disconnect callbacks before invalidating the underlying URLSession.
///
/// The barrier is open after ``complete()`` is called once; subsequent
/// ``wait()`` calls return immediately. Concurrent waiters are resumed in
/// arbitrary order on completion.
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
