import Foundation
import InnoNetwork
import Testing

@testable import InnoNetworkPersistentCache

extension PersistentResponseCacheTests {
    @Test(arguments: [-100, Int.max, Int.max - 1])
    func invalidPersistedCostsResetBeforeAnyAccounting(cost: Int) async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await seedNumericRecoveryCache(directory)
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        try rewriteNumericCosts(directory, cost: cost)
        let cache = try PersistentResponseCache(configuration: .init(directoryURL: directory))
        #expect(await cache.statistics().entryCount == 0)
        #expect(await cache.statistics().byteCount == 0)
        #expect(try Data(contentsOf: unrelated) == Data("keep".utf8))
    }

    @Test(arguments: [0, 1, 25, 1000])
    func admittedCostsAreDerivedFromBodiesAndHeaders(cost: Int) async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await seedNumericRecoveryCache(directory)
        try rewriteNumericCosts(directory, cost: cost)
        let cache = try PersistentResponseCache(configuration: .init(directoryURL: directory))
        #expect(await cache.statistics().entryCount == 2)
        #expect(await cache.statistics().byteCount == 50)
        let reopened = try PersistentResponseCache(configuration: .init(directoryURL: directory))
        #expect(await reopened.statistics().byteCount == 50)
    }

    private func seedNumericRecoveryCache(_ directory: URL) async throws {
        let cache = try PersistentResponseCache(configuration: .init(directoryURL: directory))
        for id in ["a", "b"] {
            await cache.set(
                .init(method: "GET", url: "https://example.com/\(id)"),
                .init(
                    data: Data("ok".utf8), statusCode: 200, headers: ["Cache-Control": "max-age=60"], storedAt: Date()))
        }
        #expect(await cache.statistics().byteCount == 50)
    }

    private func rewriteNumericCosts(_ directory: URL, cost: Int) throws {
        let indexURL = directory.appendingPathComponent("index.json")
        var index = try JSONDecoder.persistentCache.decode(
            PersistentResponseCache.Index.self, from: Data(contentsOf: indexURL))
        for key in index.entries.keys { index.entries[key]?.byteCost = cost }
        try JSONEncoder.persistentCache.encode(index).write(to: indexURL, options: .atomic)
    }
}
