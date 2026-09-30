import Darwin
import Foundation
import Testing

@testable import InnoNetworkDownload

@Suite("Download sequence recovery")
struct DownloadSequenceRecoveryTests {
    @Test func exhaustedBatchIsRebasedBeforeAssigningOffsets() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try await fixture(base, sequence: Int64.max - 2)
        let store = try AppendLogDownloadTaskStore(sessionIdentifier: "sequence", baseDirectoryURL: base)
        let records = ["a", "b", "c"].map {
            DownloadTaskPersistence.Record(
                id: $0, url: URL(string: "https://example.com/\($0)")!, destinationURL: base.appendingPathComponent($0))
        }
        try await store.markTerminal(ids: Set(records.map(\.id)), inserting: records)
        let reopened = try AppendLogDownloadTaskStore(sessionIdentifier: "sequence", baseDirectoryURL: base)
        #expect(Set(await reopened.allRecords().map(\.id)) == ["a", "b", "c"])
    }

    @Test func failedRebasePreservesAuthoritativeLog() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = try await fixture(base, sequence: Int64.max - 1)
        let log = directory.appendingPathComponent("events.log")
        let before = try Data(contentsOf: log)
        let store = try AppendLogDownloadTaskStore(
            sessionIdentifier: "sequence", baseDirectoryURL: base,
            fsync: { _ in
                errno = EIO
                return -1
            })
        await #expect(throws: POSIXError.self) {
            try await store.upsert(
                id: "new", url: URL(string: "https://example.com/new")!,
                destinationURL: base.appendingPathComponent("new"), resumeData: nil)
        }
        #expect(try Data(contentsOf: log) == before)
        let reopened = try AppendLogDownloadTaskStore(sessionIdentifier: "sequence", baseDirectoryURL: base)
        #expect(await reopened.allRecords().isEmpty)
    }

    @Test(arguments: [-1, Int64.max])
    func invalidSuffixPreservesPrefixAndContinuesWriting(sequence: Int64) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = try await fixture(base, sequence: sequence)
        let store = try AppendLogDownloadTaskStore(sessionIdentifier: "sequence", baseDirectoryURL: base)
        #expect(await store.allRecords().map(\.id) == ["seed"])
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
                $0.hasPrefix("events.corrupted-")
            })
        try await store.upsert(
            id: "new", url: URL(string: "https://example.com/new")!, destinationURL: base.appendingPathComponent("new"),
            resumeData: nil)
        let reopened = try AppendLogDownloadTaskStore(sessionIdentifier: "sequence", baseDirectoryURL: base)
        #expect(Set(await reopened.allRecords().map(\.id)) == ["seed", "new"])
    }

    @Test(arguments: [1, Int64.max - 1])
    func validRemovalAndExhaustedSequenceCanBeFollowedByWrites(sequence: Int64) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try await fixture(base, sequence: sequence)
        let store = try AppendLogDownloadTaskStore(sessionIdentifier: "sequence", baseDirectoryURL: base)
        #expect(await store.allRecords().isEmpty)
        try await store.upsert(
            id: "new", url: URL(string: "https://example.com/new")!, destinationURL: base.appendingPathComponent("new"),
            resumeData: nil)
        let reopened = try AppendLogDownloadTaskStore(sessionIdentifier: "sequence", baseDirectoryURL: base)
        #expect(await reopened.allRecords().map(\.id) == ["new"])
    }

    private func fixture(_ base: URL, sequence: Int64) async throws -> URL {
        let store = try AppendLogDownloadTaskStore(sessionIdentifier: "sequence", baseDirectoryURL: base)
        try await store.upsert(
            id: "seed", url: URL(string: "https://example.com/seed")!,
            destinationURL: base.appendingPathComponent("seed"), resumeData: nil)
        let directory = base.appendingPathComponent("InnoNetworkDownload").appendingPathComponent(
            DownloadSessionStorageKey.component(for: "sequence"))
        let log = directory.appendingPathComponent("events.log")
        var data = try Data(contentsOf: log)
        data.append(
            try JSONSerialization.data(withJSONObject: [
                "sequence": NSNumber(value: sequence), "timestamp": 0, "kind": "remove", "taskID": "seed",
            ]))
        data.append(10)
        try data.write(to: log)
        return directory
    }
}
