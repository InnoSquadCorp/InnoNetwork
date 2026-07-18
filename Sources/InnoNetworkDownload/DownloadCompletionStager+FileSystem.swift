import CryptoKit
import Darwin
import Foundation

extension DownloadCompletionStager {
    func validatedSourceByteCount(at sourceURL: URL) throws -> Int64 {
        guard sourceURL.isFileURL,
            sourceURL.query == nil,
            sourceURL.fragment == nil
        else {
            throw DownloadCompletionStagingError.invalidSource
        }
        switch try inspectNode(at: sourceURL.standardizedFileURL) {
        case .regularFile(let byteCount):
            return byteCount
        case .symbolicLink:
            throw DownloadCompletionStagingError.sourceIsSymbolicLink
        case .directory:
            throw DownloadCompletionStagingError.sourceIsDirectory
        case .other:
            throw DownloadCompletionStagingError.sourceIsNotRegularFile
        case .missing:
            throw DownloadCompletionStagingError.invalidSource
        }
    }

    func regularFileSHA256(at url: URL) throws -> String {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw DownloadCompletionStagingError.fileSystemFailure(
                String(cString: strerror(errno))
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw DownloadCompletionStagingError.fileSystemFailure(
                String(cString: strerror(errno))
            )
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw DownloadCompletionStagingError.sourceIsNotRegularFile
        }

        var hasher = SHA256()
        var observedByteCount: Int64 = 0
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                observedByteCount += Int64(data.count)
                hasher.update(data: data)
            }
        } catch {
            throw DownloadCompletionStagingError.fileSystemFailure(
                String(describing: error)
            )
        }
        guard observedByteCount == Int64(status.st_size) else {
            throw DownloadCompletionStagingError.payloadSizeMismatch(
                expected: Int64(status.st_size),
                actual: observedByteCount
            )
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func rejectExistingArtifacts(
        forKey key: String,
        taskID: String,
        payloadURL: URL,
        manifestURL: URL
    ) throws {
        let manifestNode = try inspectNode(at: manifestURL)
        if case .regularFile = manifestNode,
            let data = try? Data(contentsOf: manifestURL),
            let existing = try? JSONDecoder().decode(StagedCompletion.Manifest.self, from: data),
            existing.taskID != taskID
        {
            throw DownloadCompletionStagingError.manifestTaskIDCollision(key)
        }
        guard case .missing = manifestNode else {
            throw DownloadCompletionStagingError.artifactsAlreadyExist(key)
        }
        guard case .missing = try inspectNode(at: payloadURL) else {
            throw DownloadCompletionStagingError.artifactsAlreadyExist(key)
        }
    }

    func canonicalRoot(
        fileManager: FileManager,
        createIfMissing: Bool
    ) throws -> URL? {
        let standardizedRoot = directoryURL.standardizedFileURL
        guard standardizedRoot.isFileURL,
            standardizedRoot.query == nil,
            standardizedRoot.fragment == nil
        else {
            throw DownloadCompletionStagingError.invalidStagingRoot
        }
        if createIfMissing {
            do {
                try fileManager.createDirectory(
                    at: standardizedRoot,
                    withIntermediateDirectories: true
                )
            } catch {
                throw DownloadCompletionStagingError.fileSystemFailure(
                    String(describing: error)
                )
            }
        }

        switch try inspectNode(at: standardizedRoot) {
        case .missing:
            return nil
        case .directory:
            let canonicalRoot = standardizedRoot.resolvingSymlinksInPath().standardizedFileURL
            guard case .directory = try inspectNode(at: canonicalRoot) else {
                throw DownloadCompletionStagingError.invalidStagingRoot
            }
            DownloadOwnedStorageProtection.apply(to: canonicalRoot, fileManager: fileManager)
            return canonicalRoot
        case .regularFile, .symbolicLink, .other:
            throw DownloadCompletionStagingError.invalidStagingRoot
        }
    }

    func artifactURLs(
        forKey key: String,
        rootURL: URL
    ) throws -> (payloadURL: URL, manifestURL: URL) {
        guard Self.isValidKey(key) else {
            throw DownloadCompletionStagingError.invalidKey
        }
        let payloadURL = rootURL.appendingPathComponent(
            Self.journalPrefix + key + Self.payloadSuffix,
            isDirectory: false
        ).standardizedFileURL
        let manifestURL = rootURL.appendingPathComponent(
            Self.journalPrefix + key + Self.manifestSuffix,
            isDirectory: false
        ).standardizedFileURL
        guard payloadURL.deletingLastPathComponent() == rootURL,
            manifestURL.deletingLastPathComponent() == rootURL
        else {
            throw DownloadCompletionStagingError.artifactEscapesStagingRoot
        }
        return (payloadURL, manifestURL)
    }

    static func artifactKey(fromFileName fileName: String) -> String? {
        guard fileName.hasPrefix(journalPrefix) else { return nil }
        let suffix: String
        if fileName.hasSuffix(payloadSuffix) {
            suffix = payloadSuffix
        } else if fileName.hasSuffix(manifestSuffix) {
            suffix = manifestSuffix
        } else {
            return nil
        }
        let start = fileName.index(fileName.startIndex, offsetBy: journalPrefix.count)
        let end = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        let key = String(fileName[start..<end])
        return isValidKey(key) ? key : nil
    }

    package static func isValidKey(_ key: String) -> Bool {
        key.utf8.count == 64
            && key.utf8.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39)
                    || ($0 >= 0x61 && $0 <= 0x66)
            }
    }

    func inspectNode(at url: URL) throws -> StagingNode {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { representation -> Int32 in
            guard let representation else { return -1 }
            return lstat(representation, &status)
        }
        if result == 0 {
            switch status.st_mode & S_IFMT {
            case S_IFREG:
                return .regularFile(byteCount: Int64(status.st_size))
            case S_IFDIR:
                return .directory
            case S_IFLNK:
                return .symbolicLink
            default:
                return .other
            }
        }
        let code = errno
        if code == ENOENT || code == ENOTDIR {
            return .missing
        }
        throw DownloadCompletionStagingError.fileSystemFailure(
            String(cString: strerror(code))
        )
    }

    func hasNode(at url: URL) throws -> Bool {
        if case .missing = try inspectNode(at: url) {
            return false
        }
        return true
    }

    func removeBoundedArtifact(
        at url: URL,
        fileManager: FileManager
    ) throws {
        switch try inspectNode(at: url) {
        case .missing:
            return
        case .regularFile, .symbolicLink:
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw DownloadCompletionStagingError.fileSystemFailure(
                    String(describing: error)
                )
            }
        case .directory, .other:
            throw DownloadCompletionStagingError.unsupportedArtifact(url.lastPathComponent)
        }
    }

    func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    func synchronizeDirectory(at url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY)
        }
        guard descriptor >= 0 else {
            throw DownloadCompletionStagingError.fileSystemFailure(
                String(cString: strerror(errno))
            )
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw DownloadCompletionStagingError.fileSystemFailure(
                String(cString: strerror(errno))
            )
        }
    }

    enum StagingNode {
        case missing
        case regularFile(byteCount: Int64)
        case directory
        case symbolicLink
        case other
    }

    static func defaultDirectoryURL() -> URL {
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
