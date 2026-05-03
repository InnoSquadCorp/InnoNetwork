import Foundation

@testable import InnoNetworkDownload

/// In-memory `DownloadTaskStore` used by the Download test suites so the
/// stub harness does not touch disk via `AppendLogDownloadTaskStore`.
/// Shared by `StubDownloadHarness`, `DownloadRetryTimingTests`, and the
/// restore-path tests that need to pre-populate persistence before the
/// manager starts its restore coordinator.
///
/// Internal (not `private`) so tests can construct a store, seed records,
/// and hand it to the harness / manager without ad-hoc duplicates.
actor InMemoryDownloadTaskStore: DownloadTaskStore {
    private var records: [String: DownloadTaskPersistence.Record] = [:]
    private var shouldFailRemove = false
    private var shouldFailUpsert = false

    init(seed: [DownloadTaskPersistence.Record] = []) {
        for record in seed {
            records[record.id] = record
        }
    }

    func setRemoveFailure(_ shouldFail: Bool) {
        shouldFailRemove = shouldFail
    }

    func setUpsertFailure(_ shouldFail: Bool) {
        shouldFailUpsert = shouldFail
    }

    func upsert(id: String, url: URL, destinationURL: URL, resumeData: Data?) async throws {
        if shouldFailUpsert {
            throw InMemoryDownloadTaskStoreError.upsertFailed(id)
        }
        records[id] = DownloadTaskPersistence.Record(
            id: id,
            url: url,
            destinationURL: destinationURL,
            resumeData: resumeData
        )
    }

    func updateResumeData(id: String, resumeData: Data?) async throws {
        guard let record = records[id] else { return }
        try await upsert(id: id, url: record.url, destinationURL: record.destinationURL, resumeData: resumeData)
    }

    func remove(id: String) async throws {
        if shouldFailRemove {
            throw InMemoryDownloadTaskStoreError.removeFailed(id)
        }
        records.removeValue(forKey: id)
    }

    func remove(ids: Set<String>) async throws {
        if shouldFailRemove {
            throw InMemoryDownloadTaskStoreError.bulkRemoveFailed(ids)
        }
        for id in ids {
            records.removeValue(forKey: id)
        }
    }

    func record(forID id: String) async -> DownloadTaskPersistence.Record? {
        records[id]
    }

    func allRecords() async -> [DownloadTaskPersistence.Record] {
        Array(records.values)
    }

    func id(forURL url: URL?) async -> String? {
        guard let url else { return nil }
        return records.values.first(where: { $0.url == url })?.id
    }

    func prune(keeping ids: Set<String>) async throws {
        records = records.filter { ids.contains($0.key) }
    }
}


enum InMemoryDownloadTaskStoreError: Error, Equatable {
    case removeFailed(String)
    case bulkRemoveFailed(Set<String>)
    case upsertFailed(String)
}
