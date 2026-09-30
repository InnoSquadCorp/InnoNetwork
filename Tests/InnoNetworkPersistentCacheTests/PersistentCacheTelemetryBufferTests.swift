import Foundation
import InnoNetwork
import Testing

@testable import InnoNetworkPersistentCache

@Suite("Bounded persistent cache telemetry")
struct PersistentCacheTelemetryBufferTests {
    @Test("Alternating reasons remain bounded and retain exact totals")
    func alternatingReasons() {
        let reasons: [PersistentResponseCacheEvictionReason] = [
            .storageBudget, .policyRejected, .missingBody, .entryTooLarge, .unreferencedBody,
        ]
        var buffer = PersistentCacheTelemetryBuffer()
        for _ in 0..<10_000 {
            for reason in reasons {
                buffer.append(.scrubbedEntries(reason: reason, count: 2, byteCount: 17))
            }
        }
        let expected = reasons.map {
            PersistentResponseCacheTelemetryEvent.scrubbedEntries(reason: $0, count: 20_000, byteCount: 170_000)
        }
        #expect(buffer.events == expected)
        #expect(buffer.drain() == expected)
        #expect(buffer.events.isEmpty)
        #expect(buffer.drain().isEmpty)
        buffer.append(.scrubbedEntries(reason: .missingBody, count: 1, byteCount: 4))
        #expect(buffer.events == [.scrubbedEntries(reason: .missingBody, count: 1, byteCount: 4)])
    }

    @Test("Initialization aggregates and counters saturate independently")
    func saturation() {
        var buffer = PersistentCacheTelemetryBuffer([
            .scrubbedEntries(reason: .missingBody, count: Int.max - 1, byteCount: 10),
            .scrubbedEntries(reason: .missingBody, count: 2, byteCount: 20),
            .scrubbedEntries(reason: .storageBudget, count: 1, byteCount: Int.max),
        ])
        buffer.append(.scrubbedEntries(reason: .storageBudget, count: 2, byteCount: 1))
        #expect(
            buffer.events == [
                .scrubbedEntries(reason: .missingBody, count: .max, byteCount: 30),
                .scrubbedEntries(reason: .storageBudget, count: 3, byteCount: .max),
            ])
        buffer.append(.scrubbedEntries(reason: .missingBody, count: 0, byteCount: .max))
        buffer.append(.scrubbedEntries(reason: .missingBody, count: -1, byteCount: .max))
        #expect(buffer.events[0] == .scrubbedEntries(reason: .missingBody, count: .max, byteCount: 30))
    }

    @Test("Concurrent callers share a bounded actor buffer; draining preserves statistics")
    func cacheIntegration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(configuration: .init(directoryURL: directory, maxEntries: 1))
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<128 {
                group.addTask {
                    await cache.set(
                        ResponseCacheKey(method: "GET", url: "https://example.com/\(index)"),
                        CachedResponse(data: Data([42]))
                    )
                }
            }
        }
        #expect(
            await cache.telemetrySnapshot() == [.scrubbedEntries(reason: .storageBudget, count: 127, byteCount: 127)])
        #expect(await cache.statistics().evictionCount == 127)
        #expect(await cache.drainTelemetryEvents().count == 1)
        #expect(await cache.telemetrySnapshot().isEmpty)
        #expect(await cache.statistics().evictionCount == 127)
        await cache.set(
            ResponseCacheKey(method: "GET", url: "https://example.com/final"), CachedResponse(data: Data([1])))
        #expect(
            await cache.drainTelemetryEvents() == [.scrubbedEntries(reason: .storageBudget, count: 1, byteCount: 1)])
    }
}
