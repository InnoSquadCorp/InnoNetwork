import Foundation

/// Moves URLSession-owned completion files into library-owned storage before
/// the download delegate callback returns.
///
/// `URLSessionDownloadDelegate` only guarantees the lifetime of the supplied
/// file URL for the duration of `didFinishDownloadingTo`. Keeping the move in
/// this synchronous helper makes that ownership transfer explicit and keeps
/// actor scheduling out of the delegate contract.
package struct DownloadCompletionStager: Sendable {
    package let directoryURL: URL

    package init(directoryURL: URL = Self.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
    }

    package static func directoryURL(for configuration: DownloadConfiguration) -> URL {
        let fileManager = FileManager.default
        let baseDirectory =
            configuration.persistenceBaseDirectoryURL
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return
            baseDirectory
            .appendingPathComponent("InnoNetworkDownload", isDirectory: true)
            .appendingPathComponent(configuration.sessionIdentifier, isDirectory: true)
            .appendingPathComponent("CompletionStaging", isDirectory: true)
    }

    package func stage(_ sourceURL: URL, taskIdentifier: Int) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let stagedURL = directoryURL.appendingPathComponent(
            "download-\(taskIdentifier)-\(UUID().uuidString).tmp",
            isDirectory: false
        )

        do {
            try fileManager.moveItem(at: sourceURL, to: stagedURL)
            return stagedURL
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            throw error
        }
    }

    package static func removeIfPresent(_ url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    private static func defaultDirectoryURL() -> URL {
        let fileManager = FileManager.default
        let baseDirectory =
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return
            baseDirectory
            .appendingPathComponent("InnoNetworkDownload", isDirectory: true)
            .appendingPathComponent("CompletionStaging", isDirectory: true)
    }
}
