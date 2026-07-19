import Foundation

/// Mutable coordination state owned exclusively by ``DownloadManager``'s
/// actor executor. Collaborators such as the runtime registry and persistence
/// store own their own state; this value contains only cross-step manager
/// bookkeeping that must move atomically with manager lifecycle decisions.
struct DownloadManagerState {
    // Restoration acknowledgement and background-session boundary state.
    var pendingRestoreFailures: Set<String> = []
    var drainingRestoreFailureTaskIDs: Set<String> = []
    var restoreFailureDrainWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    var pendingRestoreCompletions: Set<String> = []
    var drainingRestoreCompletionTaskIDs: Set<String> = []
    var provisionalBackgroundRestoreFailureIDs: Set<String> = []
    var backgroundRestoreSnapshotPrepared = false
    var backgroundRestoreBoundaryPending = false
    var backgroundRestoreEventsFinished = false
    var pendingBackgroundSessionCompletions: [@Sendable () -> Void] = []

    // Transfer command serialization and manager-owned workers.
    var inactivityWatchdogTask: Task<Void, Never>?
    var pausingTaskIDs: Set<String> = []
    var resumingTaskIDs: Set<String> = []
    var pausingTaskIdentifiers: [String: Int] = [:]
    var deferredFailureTasks: [UUID: Task<Void, Never>] = [:]

    // Shutdown admission and drain state.
    var shutdownTrackedOperationCount = 0
    var shutdownTrackedOperationWaiters: [CheckedContinuation<Void, Never>] = []
}
