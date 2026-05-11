import Foundation
import os

/// Opt-in policy for coalescing identical in-flight transport requests.
///
/// Coalescing is disabled by default. When enabled, the client shares a single
/// raw transport result among matching requests and decodes the result
/// separately for each caller.
///
/// ## Authorization headers and coalescing
///
/// `Authorization` participates in the dedup key by default, so callers
/// presenting different tokens never share a transport. That is the safe
/// default — it prevents one caller's 401 from being delivered to a peer
/// who carries a fresh token. Pair coalescing with ``RefreshTokenPolicy``
/// directly: the refresh policy recovers token-mismatch waiters individually
/// after the originating request returns 401, so each caller still ends up
/// with the result that matches its own credentials.
///
/// To opt into Authorization-agnostic dedup (e.g. an internal service where
/// every caller in the cohort shares the same token), pass `"Authorization"`
/// in `excludedHeaderNames`. Doing so is only safe when every coalesced
/// caller is guaranteed to be authenticated identically.
public struct RequestCoalescingPolicy: Sendable, Equatable {
    public let isEnabled: Bool
    public let methods: Set<String>
    public let excludedHeaderNames: Set<String>

    /// Disabled request coalescing.
    public static let disabled = RequestCoalescingPolicy(isEnabled: false)

    /// Coalesces `GET` requests while ignoring volatile headers such as
    /// `User-Agent` and `Date` when computing the key. `Authorization`
    /// remains part of the key, so callers with different tokens are never
    /// coalesced together.
    public static let getOnly = RequestCoalescingPolicy()

    public init(
        methods: Set<String> = ["GET"],
        excludedHeaderNames: Set<String> = ["User-Agent", "Date"]
    ) {
        self.init(isEnabled: true, methods: methods, excludedHeaderNames: excludedHeaderNames)
    }

    private init(
        isEnabled: Bool,
        methods: Set<String> = [],
        excludedHeaderNames: Set<String> = []
    ) {
        self.isEnabled = isEnabled
        self.methods = Set(methods.map { $0.uppercased() })
        self.excludedHeaderNames = Set(excludedHeaderNames.map { $0.lowercased() })
    }
}


package struct RequestDedupKey: Hashable, Sendable {
    let method: String
    let url: String
    let headers: [String]
    let body: Data?
    /// Optional lane discriminator that prevents callers from joining an
    /// in-flight transport whose result might be invalidated mid-refresh.
    /// Each caller observed during ``RefreshTokenCoordinator/isRefreshInProgress``
    /// receives a unique lane so stale 401 results cannot leak through the
    /// coalescer when `Authorization` is excluded from the key.
    let refreshLane: UUID?

    init?(request: URLRequest, policy: RequestCoalescingPolicy, refreshLane: UUID? = nil) {
        guard policy.isEnabled else { return nil }
        let method = request.httpMethod?.uppercased() ?? "GET"
        guard policy.methods.contains(method) else { return nil }
        guard let url = request.url?.absoluteString else { return nil }

        let headers =
            (request.allHTTPHeaderFields ?? [:])
            .filter { !policy.excludedHeaderNames.contains($0.key.lowercased()) }
            .map { "\($0.key.lowercased()):\($0.value)" }
            .sorted()

        self.method = method
        self.url = url
        self.headers = headers
        self.body = request.httpBody
        self.refreshLane = refreshLane
    }
}


package struct TransportResult: Sendable {
    let data: Data
    let response: HTTPURLResponse
}


package actor RequestCoalescer {
    private struct Entry {
        let id: UUID
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<TransportResult, Error>]
    }

    private var entries: [RequestDedupKey: Entry] = [:]
    /// Waiter IDs that were cancelled before their `register` call reached the
    /// actor. Each entry is consumed by either `register` (matching ID arrives
    /// and is short-circuited via `removeCancelledWaiter`) or by `finish`
    /// (entry completion clears the whole bucket), so the dictionary cannot
    /// retain entries indefinitely as long as `withCheckedThrowingContinuation`
    /// is honoured—each `run` call always triggers exactly one `register`.
    private var cancelledWaiters: [RequestDedupKey: Set<UUID>] = [:]

    /// Synchronously-marked cancellation flags. ``withTaskCancellationHandler``'s
    /// `onCancel` closure executes outside actor isolation, so reaching the
    /// actor for the existing `cancelWaiter(...)` path requires a `Task` hop
    /// whose scheduling latency leaves a window during which the now-cancelled
    /// waiter can still observe a success result. Mark the cancellation under
    /// an `OSAllocatedUnfairLock` first so `register(...)` and `finish(...)`
    /// — both already actor-isolated — can short-circuit synchronously without
    /// waiting for the trailing actor hop to land. The lock is private to the
    /// actor and held only for the constant-time set update, so contention is
    /// negligible.
    private let cancelMarks = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    package init() {}

    package func run(
        key: RequestDedupKey,
        operation: @escaping @Sendable () async throws -> TransportResult
    ) async throws -> TransportResult {
        let waiterID = UUID()
        try Task.checkCancellation()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(
                    key: key,
                    waiterID: waiterID,
                    continuation: continuation,
                    operation: operation
                )
            }
        } onCancel: {
            // Mark cancellation synchronously so any concurrent
            // `register(...)` / `finish(...)` running on the actor observes
            // the cancel before the trailing actor hop lands. The Task
            // below still drives the per-entry cleanup (removing the
            // waiter from `entries`, optionally cancelling the operation
            // task) — the unfair-lock mark only closes the scheduling
            // window so a continuation can't be resumed with success
            // after cancellation has been requested. The cleanup hop
            // inherits the current priority rather than asserting
            // `.userInitiated` so it does not preempt sibling waiters'
            // pending `register(...)` hops; that preemption would let an
            // about-to-join waiter miss the in-flight entry and trigger
            // a duplicate transport request.
            self.cancelMarks.withLock { marks in
                _ = marks.insert(waiterID)
            }
            Task {
                await self.cancelWaiter(key: key, waiterID: waiterID)
            }
        }
        try Task.checkCancellation()
        return result
    }

    private func register(
        key: RequestDedupKey,
        waiterID: UUID,
        continuation: CheckedContinuation<TransportResult, Error>,
        operation: @escaping @Sendable () async throws -> TransportResult
    ) {
        if consumeCancelMark(for: waiterID) || removeCancelledWaiter(key: key, waiterID: waiterID) {
            continuation.resume(throwing: CancellationError())
            return
        }

        if var entry = entries[key] {
            entry.waiters[waiterID] = continuation
            entries[key] = entry
            return
        }

        let entryID = UUID()
        entries[key] = Entry(id: entryID, task: nil, waiters: [waiterID: continuation])
        let task = Task(priority: Task.currentPriority) { @Sendable in
            do {
                let result = try await operation()
                self.finish(key: key, entryID: entryID, result: .success(result))
            } catch {
                self.finish(key: key, entryID: entryID, result: .failure(error))
            }
        }

        if var entry = entries[key], entry.id == entryID {
            entry.task = task
            entries[key] = entry
        } else {
            task.cancel()
        }
    }

    private func finish(key: RequestDedupKey, entryID: UUID, result: Result<TransportResult, Error>) {
        guard let entry = entries[key], entry.id == entryID else { return }
        entries.removeValue(forKey: key)
        cancelledWaiters.removeValue(forKey: key)
        // Snapshot any cancellation marks that arrived while the operation
        // was in flight so waiters whose `onCancel` raced past `finish`'s
        // resume site still observe a `CancellationError` instead of the
        // operation's success result.
        let cancelledIDs = cancelMarks.withLock { marks -> Set<UUID> in
            let intersection = marks.intersection(entry.waiters.keys)
            marks.subtract(intersection)
            return intersection
        }
        for (waiterID, continuation) in entry.waiters {
            if cancelledIDs.contains(waiterID) {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(with: result)
            }
        }
    }

    private func cancelWaiter(key: RequestDedupKey, waiterID: UUID) {
        // If `finish(...)` has already resumed this waiter's continuation
        // (in success or failure) it cleared the cancel mark for us.
        // Otherwise we are the side responsible for actually delivering
        // the cancellation, so consume the mark — if no mark is present
        // here, an earlier `register(...)` already short-circuited the
        // continuation and there is nothing left to do.
        let hadMark = consumeCancelMark(for: waiterID)
        guard var entry = entries[key] else {
            if hadMark {
                cancelledWaiters[key, default: []].insert(waiterID)
            }
            return
        }
        guard let continuation = entry.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
        if entry.waiters.isEmpty {
            entry.task?.cancel()
            entries.removeValue(forKey: key)
        } else {
            entries[key] = entry
        }
    }

    private func consumeCancelMark(for waiterID: UUID) -> Bool {
        cancelMarks.withLock { $0.remove(waiterID) != nil }
    }

    private func removeCancelledWaiter(key: RequestDedupKey, waiterID: UUID) -> Bool {
        guard var waiters = cancelledWaiters[key], waiters.remove(waiterID) != nil else {
            return false
        }
        if waiters.isEmpty {
            cancelledWaiters.removeValue(forKey: key)
        } else {
            cancelledWaiters[key] = waiters
        }
        return true
    }
}
