import Foundation

package protocol DownloadTaskStore: Actor {
    func upsert(id: String, url: URL, destinationURL: URL, resumeData: Data?) async throws
    func beginStart(
        id: String,
        url: URL,
        destinationURL: URL,
        mode: DownloadTaskPersistence.StartMode,
        retryCount: Int,
        totalRetryCount: Int
    ) async throws -> Bool
    func updateResumeData(
        id: String,
        resumeData: Data?,
        lifecycle: DownloadTaskPersistence.Record.Lifecycle
    ) async throws
    func transitionResumeState(
        id: String,
        from expectedLifecycle: DownloadTaskPersistence.Record.Lifecycle?,
        to lifecycle: DownloadTaskPersistence.Record.Lifecycle,
        resumeData: Data?
    ) async throws -> Bool
    func updateRetryState(
        id: String,
        retryCount: Int,
        totalRetryCount: Int,
        retryPlan: DownloadTaskPersistence.RetryPlan?
    ) async throws -> Bool
    func beginCommit(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata
    ) async throws -> Bool
    func finishCommit(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata
    ) async throws -> Bool
    func abandonCommit(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata?
    ) async throws -> Bool
    func acknowledgeCommitOutcome(
        id: String,
        metadata: DownloadTaskPersistence.CommitMetadata,
        outcome: DownloadTaskPersistence.CommitOutcome
    ) async throws -> Bool
    func markTerminal(
        ids: Set<String>,
        inserting records: [DownloadTaskPersistence.Record]
    ) async throws
    func remove(id: String) async throws
    func remove(ids: Set<String>) async throws
    func record(forID id: String) async -> DownloadTaskPersistence.Record?
    func allRecords() async -> [DownloadTaskPersistence.Record]
    func id(forURL url: URL?) async -> String?
    func prune(keeping ids: Set<String>) async throws
}
