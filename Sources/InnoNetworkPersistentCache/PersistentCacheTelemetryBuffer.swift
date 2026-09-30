/// Bounded operational totals, not a chronological log. Each reason occupies
/// at most one slot between drains, independent of the cache's lifetime.
struct PersistentCacheTelemetryBuffer: Sendable {
    private(set) var events: [PersistentResponseCacheTelemetryEvent] = []

    init(_ events: [PersistentResponseCacheTelemetryEvent] = []) {
        for event in events { append(event) }
    }

    mutating func append(_ event: PersistentResponseCacheTelemetryEvent) {
        switch event {
        case .scrubbedEntries(let reason, let count, let byteCount):
            guard count > 0 else { return }
            let bytes = max(0, byteCount)
            for index in events.indices {
                if case .scrubbedEntries(let existingReason, let existingCount, let existingBytes) = events[index],
                    existingReason == reason
                {
                    events[index] = .scrubbedEntries(
                        reason: reason,
                        count: Self.add(existingCount, count),
                        byteCount: Self.add(existingBytes, bytes)
                    )
                    return
                }
            }
            events.append(.scrubbedEntries(reason: reason, count: count, byteCount: bytes))
        }
    }

    mutating func drain() -> [PersistentResponseCacheTelemetryEvent] {
        let snapshot = events
        events.removeAll(keepingCapacity: true)
        return snapshot
    }

    private static func add(_ lhs: Int, _ rhs: Int) -> Int {
        lhs > Int.max - rhs ? .max : lhs + rhs
    }
}
