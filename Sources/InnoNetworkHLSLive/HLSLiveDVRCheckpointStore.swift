import Darwin
import Foundation
import InnoNetworkHLS

struct HLSLiveDVRCheckpointStore: Sendable {
    private static let maximumCheckpointBytes = 8 * 1024 * 1024
    private static let maximumFileRecordCount = 40000

    let rootURL: URL
    let workspace: HLSLiveDVRWorkspace
    private let ownerURL: URL
    private let checkpointURL: URL
    private let ownerData: Data

    init(destinationURL: URL) {
        let rootURL =
            destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationURL.lastPathComponent).live-dvr-recovery",
                isDirectory: true
            )
        self.rootURL = rootURL
        ownerURL = rootURL.appendingPathComponent(".owner")
        checkpointURL = rootURL.appendingPathComponent(
            "checkpoint.json"
        )
        ownerData = Data(
            ("InnoNetworkHLSLive.Recovery.v1:"
                + HLSContentFingerprint.sha256(
                    destinationURL.standardizedFileURL.path
                )).utf8
        )
        workspace = HLSLiveDVRWorkspace(
            directoryURL: rootURL.appendingPathComponent(
                "package",
                isDirectory: true
            )
        )
    }

    func prepareFresh() throws -> HLSLiveDVRWorkspace {
        let fileManager = FileManager.default
        if nodeExists(rootURL) {
            try validateOwnedRoot()
            if nodeExists(checkpointURL) {
                throw HLSLiveDVRError.recoveryAlreadyExists
            }
            try fileManager.removeItem(at: rootURL)
        }
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            Self.applyOwnedStorageAttributes(to: rootURL)
            try ownerData.write(
                to: ownerURL,
                options: [.withoutOverwriting]
            )
            Self.applyOwnedStorageAttributes(to: ownerURL)
            try fileManager.createDirectory(
                at: workspace.directoryURL.appendingPathComponent(
                    "resources",
                    isDirectory: true
                ),
                withIntermediateDirectories: true
            )
            try Self.synchronizeFile(at: ownerURL)
            try Self.synchronizeDirectory(at: rootURL)
        } catch let error as HLSLiveDVRError {
            throw error
        } catch {
            try? fileManager.removeItem(at: rootURL)
            throw HLSLiveDVRError.storageFailed
        }
        return workspace
    }

    func resume(
        sourceURL: URL
    ) throws -> (HLSLiveDVRWorkspace, HLSLiveDVRCheckpoint) {
        guard nodeExists(rootURL) else {
            throw HLSLiveDVRError.recoveryUnavailable
        }
        do {
            try validateOwnedRoot()
            guard try isDirectory(workspace.directoryURL),
                try isRegularFile(checkpointURL),
                let byteCount = try fileSize(at: checkpointURL),
                byteCount <= Int64(Self.maximumCheckpointBytes)
            else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            let checkpointData = try boundedCheckpointData()
            let checkpoint = try JSONDecoder().decode(
                HLSLiveDVRCheckpoint.self,
                from: checkpointData
            )
            guard
                checkpoint.schemaVersion
                    == HLSLiveDVRCheckpoint.schemaVersion
            else {
                throw HLSLiveDVRError.recoveryMismatch
            }
            guard
                checkpoint.sourceURLSHA256
                    == HLSLiveDVRRecoveryIdentity.sourceURLSHA256(
                        sourceURL
                    )
            else {
                throw HLSLiveDVRError.recoveryMismatch
            }
            try validateFiles(checkpoint.files)
            try removeUntrackedWorkspaceItems(
                retaining: checkpoint.files
            )
            return (workspace, checkpoint)
        } catch let error as HLSLiveDVRError {
            throw error
        } catch {
            throw HLSLiveDVRError.recoveryCorrupted
        }
    }

    func save(
        _ checkpoint: HLSLiveDVRCheckpoint,
        synchronizing newFiles: [HLSLiveDVRCheckpoint.FileRecord]
    ) throws {
        do {
            try validateOwnedRoot()
            try validateSynchronizationScope(
                newFiles,
                checkpoint: checkpoint
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(checkpoint)
            guard data.count <= Self.maximumCheckpointBytes else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            try synchronizeResources(newFiles)
            try data.write(to: checkpointURL, options: .atomic)
            Self.applyOwnedStorageAttributes(to: checkpointURL)
            try Self.synchronizeFile(at: checkpointURL)
            try Self.synchronizeDirectory(at: rootURL)
        } catch let error as HLSLiveDVRError {
            throw error
        } catch {
            throw HLSLiveDVRError.storageFailed
        }
    }

    func cleanup() throws {
        guard nodeExists(rootURL) else {
            return
        }
        do {
            try validateOwnedRoot()
            try FileManager.default.removeItem(at: rootURL)
        } catch let error as HLSLiveDVRError {
            throw error
        } catch {
            throw HLSLiveDVRError.storageFailed
        }
    }

    private func validateFiles(
        _ files: [HLSLiveDVRCheckpoint.FileRecord]
    ) throws {
        guard files.count <= Self.maximumFileRecordCount else {
            throw HLSLiveDVRError.recoveryCorrupted
        }
        var paths: Set<String> = []
        for file in files {
            guard file.byteCount > 0,
                file.contentSHA256.count == 64,
                paths.insert(file.relativePath).inserted,
                let url = safeResourceURL(for: file.relativePath),
                try isRegularFile(url),
                try fileSize(at: url) == file.byteCount,
                try HLSContentFingerprint.sha256(contentsOf: url)
                    == file.contentSHA256
            else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
        }
    }

    private func boundedCheckpointData() throws -> Data {
        let handle = try FileHandle(forReadingFrom: checkpointURL)
        defer {
            try? handle.close()
        }
        var data = Data()
        while data.count <= Self.maximumCheckpointBytes {
            let remaining = Self.maximumCheckpointBytes + 1 - data.count
            guard
                let chunk = try handle.read(
                    upToCount: min(64 * 1024, remaining)
                ), !chunk.isEmpty
            else {
                break
            }
            data.append(chunk)
        }
        guard !data.isEmpty,
            data.count <= Self.maximumCheckpointBytes
        else {
            throw HLSLiveDVRError.recoveryCorrupted
        }
        return data
    }

    private func removeUntrackedWorkspaceItems(
        retaining files: [HLSLiveDVRCheckpoint.FileRecord]
    ) throws {
        let fileManager = FileManager.default
        let retainedPaths = Set(files.map(\.relativePath))
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard
            let enumerator = fileManager.enumerator(
                at: workspace.directoryURL,
                includingPropertiesForKeys: Array(keys)
            )
        else {
            throw HLSLiveDVRError.recoveryCorrupted
        }
        let rootPath = workspace.directoryURL.standardizedFileURL.path
        var untrackedFiles: [URL] = []
        var directories: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            let itemPath = item.standardizedFileURL.path
            guard itemPath.hasPrefix(rootPath + "/") else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            let relativePath = String(
                itemPath.dropFirst(rootPath.count + 1)
            )
            if values.isRegularFile == true {
                if !retainedPaths.contains(relativePath) {
                    untrackedFiles.append(item)
                }
            } else if values.isDirectory == true {
                directories.append(item)
            } else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
        }
        for file in untrackedFiles {
            try fileManager.removeItem(at: file)
        }
        for directory in directories.sorted(
            by: { $0.path.count > $1.path.count }
        ) {
            let contents = try fileManager.contentsOfDirectory(
                atPath: directory.path
            )
            if contents.isEmpty {
                try fileManager.removeItem(at: directory)
            }
        }
    }

    private func synchronizeResourceDirectories(
        for files: [HLSLiveDVRCheckpoint.FileRecord]
    ) throws {
        let workspaceURL = workspace.directoryURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var directories: Set<URL> = [workspaceURL]
        for file in files {
            guard let fileURL = safeResourceURL(for: file.relativePath)
            else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            var directory = fileURL.deletingLastPathComponent()
            while directory != workspaceURL {
                guard directory.path.hasPrefix(workspaceURL.path + "/")
                else {
                    throw HLSLiveDVRError.recoveryCorrupted
                }
                directories.insert(directory)
                directory = directory.deletingLastPathComponent()
            }
        }
        for directory in directories.sorted(
            by: { $0.path.count > $1.path.count }
        ) {
            try Self.synchronizeDirectory(at: directory)
        }
    }

    private func synchronizeResources(
        _ files: [HLSLiveDVRCheckpoint.FileRecord]
    ) throws {
        for file in files {
            guard let fileURL = safeResourceURL(for: file.relativePath),
                try isRegularFile(fileURL)
            else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            try Self.synchronizeFile(at: fileURL)
        }
        try synchronizeResourceDirectories(for: files)
    }

    private func validateSynchronizationScope(
        _ files: [HLSLiveDVRCheckpoint.FileRecord],
        checkpoint: HLSLiveDVRCheckpoint
    ) throws {
        var checkpointFiles: [String: HLSLiveDVRCheckpoint.FileRecord] = [:]
        for file in checkpoint.files {
            guard
                checkpointFiles.updateValue(
                    file,
                    forKey: file.relativePath
                ) == nil
            else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
        }
        var synchronizedPaths: Set<String> = []
        guard
            files.allSatisfy({ file in
                guard let expected = checkpointFiles[file.relativePath]
                else {
                    return false
                }
                return synchronizedPaths.insert(file.relativePath).inserted
                    && expected.byteCount == file.byteCount
                    && expected.contentSHA256 == file.contentSHA256
            })
        else {
            throw HLSLiveDVRError.recoveryCorrupted
        }
    }

    private func safeResourceURL(
        for relativePath: String
    ) -> URL? {
        guard !relativePath.isEmpty,
            !relativePath.hasPrefix("/"),
            !relativePath.split(separator: "/").contains("..")
        else {
            return nil
        }
        let rootPath = workspace.directoryURL
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let candidate = workspace.directoryURL
            .appendingPathComponent(relativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard candidate.path.hasPrefix(rootPath + "/") else {
            return nil
        }
        return candidate
    }

    private func validateOwnedRoot() throws {
        guard try isDirectory(rootURL),
            try isRegularFile(ownerURL),
            try fileSize(at: ownerURL)
                == Int64(ownerData.count),
            try Data(contentsOf: ownerURL) == ownerData
        else {
            throw HLSLiveDVRError.recoveryCorrupted
        }
    }

    private func isRegularFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        return values.isRegularFile == true
            && values.isSymbolicLink != true
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        return values.isDirectory == true
            && values.isSymbolicLink != true
    }

    private func fileSize(at url: URL) throws -> Int64? {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(
            Int64.init
        )
    }

    private func nodeExists(_ url: URL) -> Bool {
        var information = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return false
            }
            return lstat(path, &information) == 0
        }
    }

    private static func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }
        try handle.synchronize()
    }

    private static func synchronizeDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            close(descriptor)
        }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func applyOwnedStorageAttributes(to url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)

        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        try? FileManager.default.setAttributes(
            [
                .protectionKey:
                    FileProtectionType
                    .completeUntilFirstUserAuthentication
            ],
            ofItemAtPath: url.path
        )
        #endif
    }
}
