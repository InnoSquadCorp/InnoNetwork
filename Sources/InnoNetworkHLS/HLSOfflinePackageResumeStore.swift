import Darwin
import Foundation

struct HLSOfflinePackageWorkspace: Sendable {
    let packageURL: URL
    let stagingDirectoryURL: URL
    let retainedResources: [HLSOfflinePackageResumeStore.CompletedResource]

    var retainedByteCount: Int64 {
        retainedResources.reduce(0) { $0 + $1.byteCount }
    }

    var retainedResourceByteCounts: [Int: Int64] {
        Dictionary(
            uniqueKeysWithValues: retainedResources.map {
                ($0.index, $0.byteCount)
            }
        )
    }
}

struct HLSOfflinePackageResumeStore: Sendable {
    static let schemaVersion = 1
    private static let maximumCheckpointBytes = 8 * 1_024 * 1_024
    private static let ownerData = Data(
        "InnoNetworkHLS.OfflinePackageResume.v1".utf8
    )

    private let rootURL: URL
    private let ownerURL: URL
    private let packageURL: URL
    private let planURL: URL
    private let checkpointDirectoryURL: URL
    private let stagingDirectoryURL: URL

    init(destinationURL: URL) {
        self.rootURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationURL.lastPathComponent).hls-package-resume",
                isDirectory: true
            )
        self.ownerURL = rootURL.appendingPathComponent(".owner")
        self.packageURL = rootURL.appendingPathComponent(
            "package",
            isDirectory: true
        )
        self.planURL = rootURL.appendingPathComponent("plan.json")
        self.checkpointDirectoryURL = rootURL.appendingPathComponent(
            "completed",
            isDirectory: true
        )
        self.stagingDirectoryURL = rootURL.appendingPathComponent(
            "staging",
            isDirectory: true
        )
    }

    func prepare(
        sourceURL: URL,
        plan: HLSOfflinePackagePlan,
        aes128KeySet: HLSAES128KeySet,
        maximumTotalBytes: Int64
    ) throws -> HLSOfflinePackageWorkspace {
        let expectedPlan = PlanManifest(
            sourceURL: sourceURL,
            plan: plan,
            aes128KeySet: aes128KeySet
        )
        if nodeExists(rootURL) {
            try validateOwnedRoot()
            if let restored = try? restore(
                expectedPlan: expectedPlan,
                maximumTotalBytes: maximumTotalBytes
            ) {
                return restored
            }
            try cleanup()
        }
        try createOwnedRoot()
        try write(expectedPlan, to: planURL)
        return HLSOfflinePackageWorkspace(
            packageURL: packageURL,
            stagingDirectoryURL: stagingDirectoryURL,
            retainedResources: []
        )
    }

    func save(
        completedResource: CompletedResource
    ) throws {
        guard completedResource.index >= 0 else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        try write(
            completedResource,
            to: checkpointDirectoryURL.appendingPathComponent(
                Self.checkpointFileName(for: completedResource.index)
            )
        )
    }

    func cleanup() throws {
        guard nodeExists(rootURL) else {
            return
        }
        try validateOwnedRoot()
        try FileManager.default.removeItem(at: rootURL)
    }

    private func restore(
        expectedPlan: PlanManifest,
        maximumTotalBytes: Int64
    ) throws -> HLSOfflinePackageWorkspace {
        guard let storedPlan = try load(PlanManifest.self, at: planURL),
            storedPlan == expectedPlan,
            try isDirectory(packageURL)
        else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        let resourcePaths = expectedPlan.resourcePaths
        let completed = try loadCompletedResources(
            maximumCount: resourcePaths.count
        )
        guard completed.count <= resourcePaths.count,
            Set(completed.map(\.index)).count == completed.count,
            Set(completed.map(\.path)).count == completed.count
        else {
            throw HLSDownloadError.invalidOfflinePackage
        }

        var retainedPaths: Set<String> = []
        var retainedByteCount: Int64 = 0
        for record in completed {
            guard resourcePaths.indices.contains(record.index),
                resourcePaths[record.index] == record.path,
                record.byteCount >= 0
            else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            let fileURL = try HLSOfflinePackageIntegrity.containedURL(
                for: record.path,
                in: packageURL
            )
            let values = try fileURL.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ]
            )
            guard values.isRegularFile == true,
                values.isSymbolicLink != true,
                values.fileSize.map(Int64.init) == record.byteCount,
                try HLSOfflinePackageIntegrity.sha256(of: fileURL)
                    == record.sha256
            else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            let (nextByteCount, overflow) =
                retainedByteCount.addingReportingOverflow(
                    record.byteCount
                )
            guard !overflow, nextByteCount <= maximumTotalBytes else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            retainedByteCount = nextByteCount
            retainedPaths.insert(record.path)
        }
        try removeUnretainedArtifacts(retaining: retainedPaths)
        try? FileManager.default.removeItem(at: stagingDirectoryURL)
        return HLSOfflinePackageWorkspace(
            packageURL: packageURL,
            stagingDirectoryURL: stagingDirectoryURL,
            retainedResources: completed
        )
    }

    private func loadCompletedResources(
        maximumCount: Int
    ) throws -> [CompletedResource] {
        let fileManager = FileManager.default
        let urls = try fileManager.contentsOfDirectory(
            at: checkpointDirectoryURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: []
        )
        guard urls.count <= maximumCount else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        return try urls.map { url in
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                values.isSymbolicLink != true,
                let record = try load(CompletedResource.self, at: url),
                url.lastPathComponent
                    == Self.checkpointFileName(for: record.index)
            else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            return record
        }
    }

    private func removeUnretainedArtifacts(
        retaining retainedPaths: Set<String>
    ) throws {
        guard
            let enumerator = FileManager.default.enumerator(
                at: packageURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: []
            )
        else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard values.isSymbolicLink != true else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            let relativePath = try HLSOfflinePackageIntegrity.relativePath(
                for: fileURL,
                in: packageURL
            )
            if !retainedPaths.contains(relativePath) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func createOwnedRoot() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: checkpointDirectoryURL,
            withIntermediateDirectories: false
        )
        Self.applyOwnedStorageAttributes(to: rootURL)
        do {
            try Self.ownerData.write(
                to: ownerURL,
                options: [.withoutOverwriting]
            )
            try synchronizeFile(at: ownerURL)
            try synchronizeDirectory(at: rootURL)
        } catch {
            try? fileManager.removeItem(at: rootURL)
            throw error
        }
    }

    private func validateOwnedRoot() throws {
        guard try isDirectory(rootURL),
            try isRegularFile(ownerURL),
            try isDirectory(checkpointDirectoryURL),
            try ownerURL.resourceValues(forKeys: [.fileSizeKey])
                .fileSize == Self.ownerData.count,
            try Data(contentsOf: ownerURL) == Self.ownerData
        else {
            throw HLSDownloadError.internalTransferFailure(
                "The offline HLS package resume path is not owned by InnoNetworkHLS.",
                code: 11
            )
        }
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
                "The offline HLS package checkpoint exceeded its metadata limit.",
                code: 12
            )
        }
        try data.write(to: url, options: [.atomic])
        try synchronizeFile(at: url)
        try synchronizeDirectory(at: url.deletingLastPathComponent())
    }

    private func load<Value: Decodable>(
        _ type: Value.Type,
        at url: URL
    ) throws -> Value? {
        guard try isRegularFile(url),
            let size = try url.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize,
            size <= Self.maximumCheckpointBytes
        else {
            return nil
        }
        return try? JSONDecoder().decode(
            type,
            from: Data(contentsOf: url)
        )
    }

    private func isRegularFile(_ url: URL) throws -> Bool {
        guard nodeExists(url) else {
            return false
        }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        return values.isRegularFile == true
            && values.isSymbolicLink != true
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        guard nodeExists(url) else {
            return false
        }
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        return values.isDirectory == true
            && values.isSymbolicLink != true
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

    private func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func synchronizeDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func checkpointFileName(for index: Int) -> String {
        String(format: "%010d.json", index)
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

extension HLSOfflinePackageResumeStore {
    struct CompletedResource: Codable, Equatable, Sendable {
        let index: Int
        let path: String
        let byteCount: Int64
        let sha256: String
    }
}
