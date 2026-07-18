import Foundation
import InnoNetwork
import OSLog

extension DownloadRestoreCoordinator {
    func restoreTrackedTask(
        record: DownloadTaskPersistence.Record
    ) async -> DownloadTask? {
        guard !Task.isCancelled else { return nil }
        if await runtimeRegistry.task(withId: record.id) != nil {
            // A second system task must not steal an existing logical ID or
            // remain live beside it. The caller cancels this duplicate.
            return nil
        }
        let restoredTask = DownloadTask(
            url: record.url,
            destinationURL: record.destinationURL,
            id: record.id,
            resumeData: record.resumeData
        )
        await restoredTask.restoreRetryCounts(
            retryCount: record.retryCount ?? 0,
            totalRetryCount: record.totalRetryCount ?? 0
        )
        guard !Task.isCancelled else { return nil }
        await runtimeRegistry.add(restoredTask)
        return restoredTask
    }

    func correlatedRecord(
        for urlTask: any DownloadURLTask,
        recordsByID: [String: DownloadTaskPersistence.Record],
        recordsByURL: [URL: [DownloadTaskPersistence.Record]]
    ) -> DownloadTaskPersistence.Record? {
        guard let requestURL = urlTask.originalRequest?.url,
            let currentURL = urlTask.currentRequest?.url,
            admitsDownloadURL(requestURL),
            admitsDownloadURL(currentURL)
        else {
            return nil
        }

        let record: DownloadTaskPersistence.Record
        if let description = urlTask.taskDescription, !description.isEmpty {
            guard let describedRecord = recordsByID[description] else { return nil }
            record = describedRecord
        } else {
            let liveCandidates = recordsByURL[requestURL, default: []]
                .filter(permitsLegacyURLFallback)
            guard liveCandidates.count == 1,
                let matchingRecord = liveCandidates.first
            else {
                return nil
            }
            record = matchingRecord
            urlTask.taskDescription = record.id
        }

        guard admitsDownloadURL(record.url), record.url == requestURL else {
            // taskDescription is process-external metadata. It identifies a
            // durable row only when the retained original request matches that
            // row's admitted source. The current request may be a separately
            // admitted redirect target.
            return nil
        }
        return record
    }

    func hasPersistedPauseIntent(
        _ record: DownloadTaskPersistence.Record
    ) -> Bool {
        switch record.lifecycle {
        case .pausing, .paused:
            return true
        case .active, .resuming, .retryPending, .committing, .terminal:
            return false
        case nil:
            return record.resumeData != nil
        }
    }

    func restoresAsPausedWithoutSystemTask(
        _ record: DownloadTaskPersistence.Record
    ) -> Bool {
        record.resumeData != nil || record.lifecycle?.restoresAsPausedWithoutSystemTask == true
    }

    func permitsLiveTransport(
        _ record: DownloadTaskPersistence.Record
    ) -> Bool {
        record.lifecycle != .retryPending
            && record.lifecycle != .committing
            && record.lifecycle != .terminal
    }

    /// URL-only correlation is a compatibility fallback for legacy system
    /// tasks without `taskDescription`. Only phases that can legitimately own
    /// a live transport participate in uniqueness; paused/retry/terminal rows
    /// must not make an otherwise unambiguous active attempt look ambiguous.
    func permitsLegacyURLFallback(
        _ record: DownloadTaskPersistence.Record
    ) -> Bool {
        switch record.lifecycle {
        case .active, .resuming:
            return true
        case nil:
            return record.resumeData == nil
        case .pausing, .paused, .retryPending, .committing, .terminal:
            return false
        }
    }

    func admitsDownloadURL(_ url: URL) -> Bool {
        do {
            try NetworkURLAdmission.validate(
                url,
                policy: .http(allowsInsecure: configuration.allowsInsecureHTTP)
            )
            return true
        } catch {
            return false
        }
    }

    func pruneRejectedRecord(_ id: String) async {
        do {
            try await persistence.remove(id: id)
        } catch {
            Self.logger.fault(
                "Failed to prune URL-policy-rejected task \(id, privacy: .private(mask: .hash)) from persistence: \(String(describing: error), privacy: .private(mask: .hash)). The record remains quarantined and will be retried on the next launch."
            )
        }
    }
}
