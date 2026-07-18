import CryptoKit
import Darwin
import Foundation

/// Moves URLSession-owned completion files into library-owned storage before
/// the download delegate callback returns.
///
/// `URLSessionDownloadDelegate` only guarantees the lifetime of the supplied
/// file URL for the duration of `didFinishDownloadingTo`. Keeping the move in
/// this synchronous helper makes that ownership transfer explicit and keeps
/// actor scheduling out of the delegate contract.
package struct DownloadCompletionStager: Sendable {
    static let journalPrefix = "journal-"
    static let payloadSuffix = ".payload"
    static let manifestSuffix = ".manifest.json"

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
            .appendingPathComponent(
                DownloadSessionStorageKey.component(for: configuration.sessionIdentifier),
                isDirectory: true
            )
            .appendingPathComponent("CompletionStaging", isDirectory: true)
    }

    package func stage(_ sourceURL: URL, taskIdentifier: Int) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        DownloadOwnedStorageProtection.apply(to: directoryURL, fileManager: fileManager)

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

    /// Moves a completed URLSession payload into a deterministic, task-owned
    /// journal location and writes the correlation evidence needed after a
    /// process restart.
    ///
    /// The task id is never used as a path component. Its SHA-256 digest is the
    /// only filename input, so path separators and traversal strings remain
    /// inert metadata inside the manifest.
    package func stage(
        _ sourceURL: URL,
        taskID: String,
        originalRequestURL: URL?,
        currentRequestURL: URL?,
        fileManager: FileManager = .default
    ) throws -> StagedCompletion {
        guard !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DownloadCompletionStagingError.invalidTaskID
        }
        guard let originalRequestURL, !originalRequestURL.absoluteString.isEmpty else {
            throw DownloadCompletionStagingError.missingOriginalRequestURL
        }
        guard let currentRequestURL, !currentRequestURL.absoluteString.isEmpty else {
            throw DownloadCompletionStagingError.missingCurrentRequestURL
        }

        let expectedByteCount = try validatedSourceByteCount(at: sourceURL)
        let key = try Self.stagingKey(forTaskID: taskID)
        guard
            let rootURL = try canonicalRoot(
                fileManager: fileManager,
                createIfMissing: true
            )
        else {
            throw DownloadCompletionStagingError.invalidStagingRoot
        }
        let urls = try artifactURLs(forKey: key, rootURL: rootURL)
        try rejectExistingArtifacts(
            forKey: key,
            taskID: taskID,
            payloadURL: urls.payloadURL,
            manifestURL: urls.manifestURL
        )

        let manifest = StagedCompletion.Manifest(
            taskID: taskID,
            originalRequestURL: originalRequestURL,
            currentRequestURL: currentRequestURL,
            expectedByteCount: expectedByteCount,
            key: key
        )
        let completion = StagedCompletion(
            manifest: manifest,
            payloadURL: urls.payloadURL,
            manifestURL: urls.manifestURL
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifest)
        do {
            try manifestData.write(
                to: urls.manifestURL,
                options: [.withoutOverwriting]
            )
        } catch {
            throw error
        }
        DownloadOwnedStorageProtection.apply(to: urls.manifestURL, fileManager: fileManager)
        do {
            // Make the correlation record durable before moving the only
            // payload copy away from Foundation's temporary location.
            try synchronizeFile(at: urls.manifestURL)
            try synchronizeDirectory(at: rootURL)
        } catch {
            try? removeBoundedArtifact(at: urls.manifestURL, fileManager: fileManager)
            throw error
        }
        do {
            try fileManager.moveItem(at: sourceURL, to: urls.payloadURL)
        } catch {
            // The URLSession source still exists, so the manifest-only marker
            // can be removed without losing the only copy of the payload.
            try? removeBoundedArtifact(at: urls.manifestURL, fileManager: fileManager)
            throw error
        }

        // From this point onward the deterministic payload is the only copy.
        // Never delete it because validation or fsync reports an error. A valid
        // pair remains recoverable; an invalid pair is quarantined by launch
        // reconciliation instead of converting an I/O failure into data loss.
        DownloadOwnedStorageProtection.apply(to: urls.payloadURL, fileManager: fileManager)
        try validate(completion, fileManager: fileManager)
        do {
            try synchronizeFile(at: urls.payloadURL)
            try synchronizeDirectory(at: rootURL)
        } catch {
            // The current process can still complete the transaction. Returning
            // the validated journal is safer than throwing after ownership of
            // the URLSession temporary file has already transferred.
        }
        return completion
    }

    /// Stable SHA-256 key used by both live staging and restart recovery.
    package static func stagingKey(forTaskID taskID: String) throws -> String {
        guard !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DownloadCompletionStagingError.invalidTaskID
        }
        return SHA256.hash(data: Data(taskID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Returns the two exact task-owned journal paths under the bounded root.
    package func artifactURLs(
        forKey key: String,
        fileManager: FileManager = .default
    ) throws -> (payloadURL: URL, manifestURL: URL) {
        guard
            let rootURL = try canonicalRoot(
                fileManager: fileManager,
                createIfMissing: true
            )
        else {
            throw DownloadCompletionStagingError.invalidStagingRoot
        }
        return try artifactURLs(forKey: key, rootURL: rootURL)
    }

    /// Enumerates deterministic keys, including incomplete payload-only or
    /// manifest-only entries, so restoration can validate or clean each key.
    package func enumerateArtifactKeys(
        fileManager: FileManager = .default
    ) throws -> [String] {
        guard
            let rootURL = try canonicalRoot(
                fileManager: fileManager,
                createIfMissing: false
            )
        else {
            return []
        }
        let candidates = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var keys = Set<String>()
        for candidate in candidates {
            if let key = Self.artifactKey(fromFileName: candidate.lastPathComponent) {
                keys.insert(key)
            }
        }
        return keys.sorted()
    }

    /// Returns whether either deterministic artifact exists for a logical task.
    /// This intentionally treats incomplete and unsupported nodes as evidence:
    /// lifecycle operations must not delete persistence while restoration may
    /// still need to quarantine or reconcile that task-owned key.
    package func hasArtifacts(
        forTaskID taskID: String,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let key = try Self.stagingKey(forTaskID: taskID)
        let urls = try artifactURLs(forKey: key, fileManager: fileManager)
        return try hasNode(at: urls.payloadURL) || hasNode(at: urls.manifestURL)
    }

    /// Loads and validates one complete journal entry. Incomplete or malformed
    /// pairs fail closed and remain available to bounded cleanup.
    package func load(
        forKey key: String,
        fileManager: FileManager = .default
    ) throws -> StagedCompletion {
        let urls = try artifactURLs(forKey: key, fileManager: fileManager)
        let manifestNode = try inspectNode(at: urls.manifestURL)
        let payloadNode = try inspectNode(at: urls.payloadURL)
        guard case .regularFile = manifestNode,
            case .regularFile = payloadNode
        else {
            throw DownloadCompletionStagingError.incompleteArtifacts(key)
        }

        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: urls.manifestURL)
        } catch {
            throw DownloadCompletionStagingError.fileSystemFailure(
                String(describing: error)
            )
        }
        let manifest: StagedCompletion.Manifest
        do {
            manifest = try JSONDecoder().decode(
                StagedCompletion.Manifest.self,
                from: manifestData
            )
        } catch {
            throw DownloadCompletionStagingError.invalidManifest(key)
        }
        let completion = StagedCompletion(
            manifest: manifest,
            payloadURL: urls.payloadURL,
            manifestURL: urls.manifestURL
        )
        try validate(completion, fileManager: fileManager)
        return completion
    }

    /// Revalidates a staged value against its manifest, deterministic paths,
    /// canonical root, and on-disk regular-file metadata.
    package func validate(
        _ completion: StagedCompletion,
        fileManager: FileManager = .default
    ) throws {
        let manifest = completion.manifest
        guard !manifest.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            manifest.expectedByteCount >= 0,
            !manifest.originalRequestURL.absoluteString.isEmpty,
            !manifest.currentRequestURL.absoluteString.isEmpty
        else {
            throw DownloadCompletionStagingError.invalidManifest(manifest.key)
        }
        let expectedKey = try Self.stagingKey(forTaskID: manifest.taskID)
        guard manifest.key == expectedKey else {
            throw DownloadCompletionStagingError.manifestTaskIDCollision(manifest.key)
        }
        let expectedURLs = try artifactURLs(forKey: manifest.key, fileManager: fileManager)
        guard completion.payloadURL.standardizedFileURL == expectedURLs.payloadURL,
            completion.manifestURL.standardizedFileURL == expectedURLs.manifestURL
        else {
            throw DownloadCompletionStagingError.artifactEscapesStagingRoot
        }

        let manifestNode = try inspectNode(at: expectedURLs.manifestURL)
        let payloadNode = try inspectNode(at: expectedURLs.payloadURL)
        guard case .regularFile = manifestNode else {
            throw DownloadCompletionStagingError.incompleteArtifacts(manifest.key)
        }
        guard case .regularFile(let actualByteCount) = payloadNode else {
            throw DownloadCompletionStagingError.incompleteArtifacts(manifest.key)
        }
        guard actualByteCount == manifest.expectedByteCount else {
            throw DownloadCompletionStagingError.payloadSizeMismatch(
                expected: manifest.expectedByteCount,
                actual: actualByteCount
            )
        }
        let onDiskManifestData: Data
        do {
            onDiskManifestData = try Data(contentsOf: expectedURLs.manifestURL)
        } catch {
            throw DownloadCompletionStagingError.fileSystemFailure(
                String(describing: error)
            )
        }
        let onDiskManifest: StagedCompletion.Manifest
        do {
            onDiskManifest = try JSONDecoder().decode(
                StagedCompletion.Manifest.self,
                from: onDiskManifestData
            )
        } catch {
            throw DownloadCompletionStagingError.invalidManifest(manifest.key)
        }
        guard onDiskManifest == manifest else {
            throw DownloadCompletionStagingError.invalidManifest(manifest.key)
        }
    }

    /// Removes only the exact deterministic files represented by `completion`.
    package func cleanup(
        _ completion: StagedCompletion,
        fileManager: FileManager = .default
    ) throws {
        let expectedURLs = try artifactURLs(
            forKey: completion.manifest.key,
            fileManager: fileManager
        )
        guard completion.payloadURL.standardizedFileURL == expectedURLs.payloadURL,
            completion.manifestURL.standardizedFileURL == expectedURLs.manifestURL
        else {
            throw DownloadCompletionStagingError.artifactEscapesStagingRoot
        }
        try cleanupArtifacts(forKey: completion.manifest.key, fileManager: fileManager)
    }

    /// Removes one exact key's payload and manifest without following symlinks
    /// or traversing subdirectories. Unrelated root contents are untouched.
    package func cleanupArtifacts(
        forKey key: String,
        fileManager: FileManager = .default
    ) throws {
        let urls = try artifactURLs(forKey: key, fileManager: fileManager)
        try removeBoundedArtifact(at: urls.payloadURL, fileManager: fileManager)
        try removeBoundedArtifact(at: urls.manifestURL, fileManager: fileManager)
        try synchronizeDirectory(at: urls.payloadURL.deletingLastPathComponent())
    }

    package static func removeIfPresent(_ url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Removes completion files orphaned by a prior process lifetime.
    ///
    /// The sweep is intentionally non-recursive and restricted to this
    /// stager's generated filename shape. Directories, symbolic links, and
    /// unrelated files in the configured base directory are never touched.
    package func removeStaleFiles(fileManager: FileManager = .default) {
        guard
            let candidates = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }

        for candidate in candidates {
            let name = candidate.lastPathComponent
            guard name.hasPrefix("download-"), name.hasSuffix(".tmp") else { continue }
            guard
                let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                values.isRegularFile == true,
                values.isSymbolicLink != true
            else {
                continue
            }
            try? fileManager.removeItem(at: candidate)
        }
    }

    package func payloadSHA256(
        for completion: StagedCompletion
    ) throws -> String {
        try validate(completion)
        return try regularFileSHA256(at: completion.payloadURL)
    }

    package func validateCommittedFile(
        at url: URL,
        expectedByteCount: Int64,
        payloadSHA256: String
    ) throws {
        guard url.isFileURL, url.query == nil, url.fragment == nil else {
            throw DownloadCompletionStagingError.invalidSource
        }
        guard case .regularFile(let actualByteCount) = try inspectNode(at: url),
            actualByteCount == expectedByteCount
        else {
            throw DownloadCompletionStagingError.invalidSource
        }
        guard try regularFileSHA256(at: url) == payloadSHA256 else {
            throw DownloadCompletionStagingError.invalidManifest(url.lastPathComponent)
        }
    }

}
