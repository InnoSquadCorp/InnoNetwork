import Darwin
import Foundation

struct HLSDownloadWorkspace: Sendable {
    let partialURL: URL
    let stagingDirectoryURL: URL
    let nextResourceIndex: Int
    let assembledByteCount: Int64
}

struct HLSResumeStore: Sendable {
    private static let schemaVersion = 3
    private static let maximumCheckpointBytes = 8 * 1_024 * 1_024
    private static let ownerData = Data(
        "InnoNetworkHLS.Resume.v1".utf8
    )

    private let rootURL: URL
    private let ownerURL: URL
    private let partialURL: URL
    private let manifestURL: URL
    private let checkpointURL: URL
    private let stagingDirectoryURL: URL

    init(destinationURL: URL) {
        self.rootURL =
            destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationURL.lastPathComponent).hls-resume",
                isDirectory: true
            )
        self.ownerURL = rootURL.appendingPathComponent(
            ".owner",
            isDirectory: false
        )
        self.partialURL = rootURL.appendingPathComponent(
            "output.part",
            isDirectory: false
        )
        self.manifestURL = rootURL.appendingPathComponent(
            "manifest.json",
            isDirectory: false
        )
        self.checkpointURL = rootURL.appendingPathComponent(
            "checkpoint.json",
            isDirectory: false
        )
        self.stagingDirectoryURL = rootURL.appendingPathComponent(
            "staging",
            isDirectory: true
        )
    }

    func prepare(
        sourceURL: URL,
        mediaPlaylistIdentity: HLSContentIdentity,
        resources: [HLSResourceTransfer],
        aes128KeySet: HLSAES128KeySet = .empty,
        maximumTotalBytes: Int64
    ) throws -> HLSDownloadWorkspace {
        guard
            resources.allSatisfy({ resource in
                guard let keyURL = resource.encryption?.keyURL else {
                    return true
                }
                return aes128KeySet.fingerprint(for: keyURL) != nil
            })
        else {
            throw HLSDownloadError.invalidAES128Key
        }
        let fileManager = FileManager.default
        if nodeExists(rootURL) {
            try validateOwnedRoot()
        }
        if let manifest = try load(
            PlanManifest.self,
            at: manifestURL,
            fileManager: fileManager
        ),
            let checkpoint = try load(
                ProgressCheckpoint.self,
                at: checkpointURL,
                fileManager: fileManager
            ),
            manifest.matches(
                sourceURL: sourceURL,
                mediaPlaylistIdentity: mediaPlaylistIdentity,
                resources: resources,
                aes128KeySet: aes128KeySet
            ),
            checkpoint.matches(
                resourceCount: resources.count,
                maximumTotalBytes: maximumTotalBytes
            ),
            try isRegularFile(partialURL),
            let fileSize = try fileSize(at: partialURL),
            fileSize >= checkpoint.assembledByteCount
        {
            if fileSize > checkpoint.assembledByteCount {
                let handle = try FileHandle(forWritingTo: partialURL)
                defer {
                    try? handle.close()
                }
                try handle.truncate(
                    atOffset: UInt64(checkpoint.assembledByteCount)
                )
                try handle.synchronize()
            }
            try? fileManager.removeItem(at: stagingDirectoryURL)
            return HLSDownloadWorkspace(
                partialURL: partialURL,
                stagingDirectoryURL: stagingDirectoryURL,
                nextResourceIndex: checkpoint.nextResourceIndex,
                assembledByteCount: checkpoint.assembledByteCount
            )
        }

        try cleanup()
        try createOwnedRoot(fileManager: fileManager)
        guard fileManager.createFile(atPath: partialURL.path, contents: nil)
        else {
            throw HLSDownloadError.internalTransferFailure(
                "The resumable HLS partial file could not be created.",
                code: 5
            )
        }
        Self.applyOwnedStorageAttributes(to: partialURL)
        try saveManifest(
            sourceURL: sourceURL,
            mediaPlaylistIdentity: mediaPlaylistIdentity,
            resources: resources,
            aes128KeySet: aes128KeySet
        )
        try save(
            resourceCount: resources.count,
            nextResourceIndex: 0,
            assembledByteCount: 0
        )
        return HLSDownloadWorkspace(
            partialURL: partialURL,
            stagingDirectoryURL: stagingDirectoryURL,
            nextResourceIndex: 0,
            assembledByteCount: 0
        )
    }

    func save(
        resourceCount: Int,
        nextResourceIndex: Int,
        assembledByteCount: Int64
    ) throws {
        guard nextResourceIndex >= 0,
            nextResourceIndex <= resourceCount,
            assembledByteCount >= 0
        else {
            throw HLSDownloadError.internalTransferFailure(
                "The resumable HLS checkpoint was outside its resource plan.",
                code: 6
            )
        }
        let checkpoint = ProgressCheckpoint(
            nextResourceIndex: nextResourceIndex,
            assembledByteCount: assembledByteCount
        )
        try write(checkpoint, to: checkpointURL)
    }

    private func saveManifest(
        sourceURL: URL,
        mediaPlaylistIdentity: HLSContentIdentity,
        resources: [HLSResourceTransfer],
        aes128KeySet: HLSAES128KeySet
    ) throws {
        let manifest = PlanManifest(
            schemaVersion: Self.schemaVersion,
            sourceURLSHA256: HLSContentFingerprint.sha256(
                sourceURL.absoluteString
            ),
            mediaPlaylistIdentity: mediaPlaylistIdentity,
            resources: resources.map {
                HLSResumeResourceRecord($0, aes128KeySet: aes128KeySet)
            }
        )
        try write(manifest, to: manifestURL)
    }

    private func write<Value: Encodable>(
        _ value: Value,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumCheckpointBytes else {
            throw HLSDownloadError.internalTransferFailure(
                "The resumable HLS checkpoint exceeded its metadata limit.",
                code: 7
            )
        }
        try data.write(to: url, options: [.atomic])
        Self.applyOwnedStorageAttributes(to: url)
        try Self.synchronizeFile(at: url)
        try Self.synchronizeDirectory(at: rootURL)
    }

    func cleanup() throws {
        let fileManager = FileManager.default
        guard nodeExists(rootURL) else {
            return
        }
        try validateOwnedRoot()
        try fileManager.removeItem(at: rootURL)
    }

    private func createOwnedRoot(
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        Self.applyOwnedStorageAttributes(to: rootURL)
        do {
            try Self.ownerData.write(
                to: ownerURL,
                options: [.withoutOverwriting]
            )
            Self.applyOwnedStorageAttributes(to: ownerURL)
            try Self.synchronizeFile(at: ownerURL)
            try Self.synchronizeDirectory(at: rootURL)
        } catch {
            try? fileManager.removeItem(at: rootURL)
            throw error
        }
    }

    private func validateOwnedRoot() throws {
        guard try isDirectory(rootURL),
            try isRegularFile(ownerURL),
            let ownerSize = try fileSize(at: ownerURL),
            ownerSize == Int64(Self.ownerData.count),
            try Data(contentsOf: ownerURL) == Self.ownerData
        else {
            throw HLSDownloadError.internalTransferFailure(
                "The HLS resume path is not owned by InnoNetworkHLS.",
                code: 8
            )
        }
    }

    private func load<Value: Decodable>(
        _ type: Value.Type,
        at url: URL,
        fileManager: FileManager
    ) throws -> Value? {
        guard fileManager.fileExists(atPath: url.path),
            try isRegularFile(url),
            let size = try fileSize(at: url),
            size <= Int64(Self.maximumCheckpointBytes)
        else {
            return nil
        }
        do {
            return try JSONDecoder().decode(
                type,
                from: Data(contentsOf: url)
            )
        } catch {
            return nil
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

private extension HLSResumeStore {
    struct PlanManifest: Codable {
        let schemaVersion: Int
        let sourceURLSHA256: String
        let mediaPlaylistIdentity: HLSContentIdentity
        let resources: [HLSResumeResourceRecord]

        func matches(
            sourceURL: URL,
            mediaPlaylistIdentity: HLSContentIdentity,
            resources: [HLSResourceTransfer],
            aes128KeySet: HLSAES128KeySet
        ) -> Bool {
            schemaVersion == HLSResumeStore.schemaVersion
                && sourceURLSHA256
                    == HLSContentFingerprint.sha256(
                        sourceURL.absoluteString
                    )
                && self.mediaPlaylistIdentity == mediaPlaylistIdentity
                && self.resources
                    == resources.map {
                        HLSResumeResourceRecord(
                            $0,
                            aes128KeySet: aes128KeySet
                        )
                    }
        }
    }

    struct ProgressCheckpoint: Codable {
        let nextResourceIndex: Int
        let assembledByteCount: Int64

        func matches(
            resourceCount: Int,
            maximumTotalBytes: Int64
        ) -> Bool {
            nextResourceIndex >= 0
                && nextResourceIndex <= resourceCount
                && assembledByteCount >= 0
                && assembledByteCount <= maximumTotalBytes
                && (nextResourceIndex != 0 || assembledByteCount == 0)
        }
    }

}
