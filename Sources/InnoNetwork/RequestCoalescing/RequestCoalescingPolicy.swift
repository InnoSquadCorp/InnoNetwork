import Foundation

/// Opt-in policy for coalescing identical in-flight transport requests.
///
/// Coalescing is disabled by default. When enabled, the client shares a single
/// raw transport result among matching requests and decodes the result
/// separately for each caller.
public struct RequestCoalescingPolicy: Sendable, Equatable {
    public let isEnabled: Bool
    public let methods: Set<String>
    public let excludedHeaderNames: Set<String>

    /// Disabled request coalescing.
    public static let disabled = RequestCoalescingPolicy(isEnabled: false)

    /// Coalesces `GET` requests while ignoring volatile headers such as
    /// `User-Agent` and `Date` when computing the key.
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

    init?(request: URLRequest, policy: RequestCoalescingPolicy) {
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
    private var cancelledWaiters: [RequestDedupKey: Set<UUID>] = [:]

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
            Task { await self.cancelWaiter(key: key, waiterID: waiterID) }
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
        if removeCancelledWaiter(key: key, waiterID: waiterID) {
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
        let task = Task.detached {
            do {
                let result = try await operation()
                await self.finish(key: key, entryID: entryID, result: .success(result))
            } catch {
                await self.finish(key: key, entryID: entryID, result: .failure(error))
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
        for continuation in entry.waiters.values {
            continuation.resume(with: result)
        }
    }

    private func cancelWaiter(key: RequestDedupKey, waiterID: UUID) {
        guard var entry = entries[key] else {
            cancelledWaiters[key, default: []].insert(waiterID)
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
