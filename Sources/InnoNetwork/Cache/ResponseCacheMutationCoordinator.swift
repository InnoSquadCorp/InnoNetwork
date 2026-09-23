import Foundation

/// Serializes cache mutations per target URI and invalidates write tokens
/// captured before an unsafe response or a storage-prohibiting response.
///
/// `ResponseCache` is intentionally open to external implementations, so the
/// executor cannot assume that `set` and `invalidate` share one actor. Holding
/// this coordinator's per-target lease across each cache mutation prevents an
/// older GET from being stored after a newer mutation has invalidated it.
package actor ResponseCacheMutationCoordinator {
    package final class WriteToken: Sendable {
        let targetURI: String
        let generation: UUID
        private let owner: ResponseCacheMutationCoordinator

        fileprivate init(targetURI: String, owner: ResponseCacheMutationCoordinator) {
            self.targetURI = targetURI
            self.generation = UUID()
            self.owner = owner
        }

        deinit {
            let owner = owner
            let targetURI = targetURI
            let generation = generation
            Task { await owner.discardReleasedToken(targetURI: targetURI, generation: generation) }
        }
    }

    private struct Generation {
        weak var token: WriteToken?
        let id: UUID
    }

    private var generations: [String: Generation] = [:]
    private var activeTargets: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    package func writeToken(for targetURI: String) -> WriteToken {
        if let token = generations[targetURI]?.token { return token }
        let token = WriteToken(targetURI: targetURI, owner: self)
        generations[targetURI] = Generation(token: token, id: token.generation)
        return token
    }

    fileprivate func discardReleasedToken(targetURI: String, generation: UUID) {
        // An older token's deferred cleanup must not erase a newer generation.
        if generations[targetURI]?.id == generation {
            generations.removeValue(forKey: targetURI)
        }
    }

    /// Also sweeps expired weak slots when observing coordinator state; normal
    /// request completion removes them asynchronously through token deinit.
    package var trackedTargetCount: Int {
        generations = generations.filter { $0.value.token != nil }
        return generations.count
    }

    package func acquire(targetURI: String) async {
        if activeTargets.insert(targetURI).inserted {
            return
        }
        await withCheckedContinuation { continuation in
            waiters[targetURI, default: []].append(continuation)
        }
    }

    package func isCurrent(_ token: WriteToken) -> Bool {
        generations[token.targetURI]?.token === token
    }

    package func advanceGeneration(for targetURI: String) {
        // No tombstone is necessary: old live tokens fail the identity check
        // and any later reader obtains a newly allocated token.
        generations.removeValue(forKey: targetURI)
    }

    package func release(targetURI: String) {
        guard var queued = waiters[targetURI], !queued.isEmpty else {
            activeTargets.remove(targetURI)
            waiters.removeValue(forKey: targetURI)
            return
        }
        let next = queued.removeFirst()
        if queued.isEmpty {
            waiters.removeValue(forKey: targetURI)
        } else {
            waiters[targetURI] = queued
        }
        next.resume()
    }
}
