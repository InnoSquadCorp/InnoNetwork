import Foundation
import OSLog

// Split out of `DownloadTaskPersistence.swift` so the quarantine policy
// (rename → fallback removeItem → fault log) lives alongside its dedicated
// logger. All helpers stay `static`; this file only relocates code, no
// behaviour changes.
extension AppendLogDownloadTaskStore {

    static let quarantineLogger = Logger(
        subsystem: "innosquad.network.download",
        category: "Persistence"
    )

    /// Renames a corrupt state file out of the way so restoration can proceed
    /// with a clean slate. If the rename fails (e.g. directory ACLs are too
    /// tight or the destination already exists) we fall back to `removeItem`
    /// — leaving the corrupt file in place would cause every subsequent boot
    /// to re-discover the same corruption and start with an empty in-memory
    /// state on each launch. Both failures are surfaced as `fault` so an
    /// operator can investigate; staying silent here previously masked an
    /// infinite empty-state loop.
    static func quarantineFileIfNeeded(_ url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path()) else { return }
        let timestamp = Int(Date.now.timeIntervalSince1970)
        let directory = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let corruptedURL = directory.appendingPathComponent(
            ext.isEmpty ? "\(name).corrupted-\(timestamp)" : "\(name).corrupted-\(timestamp).\(ext)",
            isDirectory: false
        )
        do {
            try fileManager.moveItem(at: url, to: corruptedURL)
            return
        } catch {
            quarantineLogger.fault(
                "Failed to quarantine corrupt persistence file at \(url.path(), privacy: .public): \(error.localizedDescription, privacy: .public). Falling back to removeItem."
            )
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            quarantineLogger.fault(
                "Fallback removeItem also failed for \(url.path(), privacy: .public): \(error.localizedDescription, privacy: .public). Subsequent boots will re-read the corrupt file."
            )
        }
    }
}
