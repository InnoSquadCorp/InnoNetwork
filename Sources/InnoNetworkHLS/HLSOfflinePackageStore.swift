import CryptoKit
import Foundation

/// Reopens and validates application-owned offline HLS package directories.
public struct HLSOfflinePackageStore: Sendable {
    /// Creates a stateless offline-package store facade.
    public init() {}

    /// Validates and reopens a committed package directory.
    ///
    /// The returned receipt contains local package URLs. Validation rejects
    /// path traversal, symbolic links, missing or unreferenced files, invalid
    /// local playlists, unsupported manifest schemas, and schema 3 checksum
    /// mismatches.
    public func open(
        at directoryURL: URL
    ) throws -> HLSOfflinePackageReceipt {
        do {
            return try HLSOfflinePackageValidator.open(
                at: directoryURL
            )
        } catch let error as HLSDownloadError {
            throw error
        } catch {
            throw HLSDownloadError.wrappingTransferFailure(error)
        }
    }

    /// Validates a committed package without retaining its metadata.
    public func validate(
        at directoryURL: URL
    ) throws {
        _ = try open(at: directoryURL)
    }
}

enum HLSOfflinePackageIntegrity {
    private static let maximumFileCount = 1_000_000

    struct Scan: Sendable {
        let paths: Set<String>
        let records: [HLSOfflinePackageManifest.FileRecord]
        let byteCount: Int64
    }

    static func scan(
        directoryURL: URL,
        hashingFiles: Bool,
        recordExclusions: Set<String> = []
    ) throws -> Scan {
        let rootValues = try directoryURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true,
            rootValues.isSymbolicLink != true
        else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        guard
            let enumerator = FileManager.default.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ],
                options: []
            )
        else {
            throw HLSDownloadError.invalidOfflinePackage
        }

        var paths: Set<String> = []
        var records: [HLSOfflinePackageManifest.FileRecord] = []
        var byteCount: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ]
            )
            guard values.isSymbolicLink != true else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true,
                let size = values.fileSize,
                size >= 0
            else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            let relativePath = try relativePath(
                for: fileURL,
                in: directoryURL
            )
            guard paths.insert(relativePath).inserted else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            guard paths.count <= maximumFileCount else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            let (nextByteCount, overflow) =
                byteCount.addingReportingOverflow(Int64(size))
            guard !overflow else {
                throw HLSDownloadError.totalDownloadTooLarge(
                    limit: .max
                )
            }
            byteCount = nextByteCount
            guard !recordExclusions.contains(relativePath) else {
                continue
            }
            records.append(
                HLSOfflinePackageManifest.FileRecord(
                    path: relativePath,
                    byteCount: Int64(size),
                    sha256:
                        hashingFiles
                        ? try sha256(of: fileURL)
                        : ""
                )
            )
        }
        records.sort { lhs, rhs in
            Array(lhs.path.utf8).lexicographicallyPrecedes(
                Array(rhs.path.utf8)
            )
        }
        return Scan(
            paths: paths,
            records: records,
            byteCount: byteCount
        )
    }

    static func containedURL(
        for relativePath: String,
        in directoryURL: URL
    ) throws -> URL {
        guard !relativePath.isEmpty,
            relativePath.utf8.count <= 4_096,
            !relativePath.hasPrefix("/"),
            !relativePath.contains("\\"),
            !relativePath.contains("\0")
        else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard
            components.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".."
            })
        else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        let root = directoryURL.standardizedFileURL
        let candidate = root.appendingPathComponent(
            relativePath,
            isDirectory: false
        ).standardizedFileURL
        let rootPrefix =
            root.path.hasSuffix("/")
            ? root.path
            : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        return candidate
    }

    static func relativePath(
        for fileURL: URL,
        in directoryURL: URL
    ) throws -> String {
        let root = directoryURL.standardizedFileURL
        let candidate = fileURL.standardizedFileURL
        let rootPrefix =
            root.path.hasSuffix("/")
            ? root.path
            : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        let relativePath = String(candidate.path.dropFirst(rootPrefix.count))
        _ = try containedURL(for: relativePath, in: directoryURL)
        return relativePath
    }

    static func sha256(
        of fileURL: URL
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024),
            !data.isEmpty
        {
            hasher.update(data: data)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private enum HLSOfflinePackageValidator {
    private static let maximumManifestBytes = 8 * 1_024 * 1_024
    private static let maximumPlaylistBytes = 8 * 1_024 * 1_024
    private static let maximumTrackCount = 128
    private static let manifestPath = "manifest.json"

    static func open(
        at directoryURL: URL
    ) throws -> HLSOfflinePackageReceipt {
        guard directoryURL.isFileURL else {
            throw HLSDownloadError.invalidDestination
        }
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        let manifestURL = try HLSOfflinePackageIntegrity.containedURL(
            for: manifestPath,
            in: directoryURL
        )
        let manifestData = try boundedRegularFileData(
            at: manifestURL,
            maximumBytes: maximumManifestBytes
        )
        let manifest: HLSOfflinePackageManifest
        do {
            manifest = try JSONDecoder().decode(
                HLSOfflinePackageManifest.self,
                from: manifestData
            )
        } catch {
            throw HLSDownloadError.invalidOfflinePackage
        }
        guard
            (1...HLSOfflinePackageManifest.currentSchemaVersion).contains(
                manifest.schemaVersion
            )
        else {
            throw HLSDownloadError.unsupportedOfflinePackageSchema(
                version: manifest.schemaVersion
            )
        }
        guard !manifest.tracks.isEmpty,
            manifest.tracks.count <= maximumTrackCount,
            manifest.resumedResourceTransferCount >= 0
        else {
            throw HLSDownloadError.invalidOfflinePackage
        }

        let tracks = try manifest.tracks.map { try $0.descriptor() }
        guard tracks.count(where: { $0.kind == .primary }) == 1,
            tracks.count(where: { $0.kind == .iFrames }) <= 1,
            tracks.contains(where: { $0.kind == .iFrames })
                || !tracks.contains(where: { $0.kind == .iFrameVideo }),
            Set(tracks.map(\.relativePlaylistPath)).count == tracks.count
        else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        let entryPlaylistURL = try HLSOfflinePackageIntegrity.containedURL(
            for: manifest.entryPlaylistPath,
            in: directoryURL
        )
        let trackURLs = try Dictionary(
            uniqueKeysWithValues: tracks.map { track in
                (
                    track.relativePlaylistPath,
                    try HLSOfflinePackageIntegrity.containedURL(
                        for: track.relativePlaylistPath,
                        in: directoryURL
                    )
                )
            }
        )

        let scan: HLSOfflinePackageIntegrity.Scan
        do {
            scan = try HLSOfflinePackageIntegrity.scan(
                directoryURL: directoryURL,
                hashingFiles:
                    manifest.schemaVersion
                    == HLSOfflinePackageManifest.currentSchemaVersion,
                recordExclusions: [manifestPath]
            )
        } catch let error as HLSDownloadError {
            throw error
        } catch {
            throw HLSDownloadError.invalidOfflinePackage
        }
        guard scan.byteCount > 0 else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        if manifest.schemaVersion
            == HLSOfflinePackageManifest.currentSchemaVersion
        {
            guard let files = manifest.files,
                !files.isEmpty,
                files.count == Set(files.map(\.path)).count,
                files.allSatisfy(Self.isValidFileRecord),
                files.sorted(by: Self.recordOrder) == scan.records
            else {
                throw HLSDownloadError.invalidOfflinePackage
            }
        }

        let entryPlaylist = try parsePlaylist(at: entryPlaylistURL)
        guard entryPlaylist.kind == .multivariant,
            entryPlaylist.variants.count == 1,
            let entryVariant = entryPlaylist.variants.first,
            let primaryTrack = tracks.first(where: { $0.kind == .primary }),
            let primaryURL = trackURLs[primaryTrack.relativePlaylistPath],
            sameFile(entryVariant.url, primaryURL)
        else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        try validateEntryRenditions(
            entryPlaylist,
            tracks: tracks,
            trackURLs: trackURLs,
            strictMetadata:
                manifest.schemaVersion
                == HLSOfflinePackageManifest.currentSchemaVersion
        )
        let entryIFrameVariant = try validateEntryIFrameVariant(
            entryPlaylist,
            tracks: tracks,
            trackURLs: trackURLs
        )

        var expectedPaths: Set<String> = [
            manifestPath,
            manifest.entryPlaylistPath,
        ]
        var resourceCount = 0
        for track in tracks {
            guard let playlistURL = trackURLs[track.relativePlaylistPath] else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            expectedPaths.insert(track.relativePlaylistPath)
            let playlist = try parsePlaylist(at: playlistURL)
            guard playlist.kind == .media,
                let media = playlist.media
            else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            do {
                if track.kind == .iFrames
                    || track.kind == .iFrameVideo
                {
                    try HLSMediaPlaylistValidator
                        .validateIFrameTrickPlay(media)
                } else {
                    try HLSMediaPlaylistValidator
                        .validateOfflinePackage(media)
                }
            } catch {
                throw HLSDownloadError.invalidOfflinePackage
            }
            let (nextResourceCount, overflow) =
                resourceCount.addingReportingOverflow(
                    media.resources.count
                )
            guard !overflow else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            resourceCount = nextResourceCount
            for resource in media.resources {
                guard resource.url.isFileURL else {
                    throw HLSDownloadError.invalidOfflinePackage
                }
                expectedPaths.insert(
                    try HLSOfflinePackageIntegrity.relativePath(
                        for: resource.url,
                        in: directoryURL
                    )
                )
            }
        }
        guard expectedPaths == scan.paths else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        guard manifest.resumedResourceTransferCount <= resourceCount else {
            throw HLSDownloadError.invalidOfflinePackage
        }

        let selectedVariant = try manifest.selectedVariant.map { variant in
            if manifest.schemaVersion
                == HLSOfflinePackageManifest.currentSchemaVersion
            {
                guard variant.matches(entryVariant) else {
                    throw HLSDownloadError.invalidOfflinePackage
                }
            }
            return try variant.localVariant(
                at: primaryURL,
                entryVariant: entryVariant
            )
        }
        if manifest.schemaVersion
            == HLSOfflinePackageManifest.currentSchemaVersion,
            (manifest.selectedIFrameVariant == nil)
                != (entryIFrameVariant == nil)
        {
            throw HLSDownloadError.invalidOfflinePackage
        }
        let selectedIFrameVariant = try manifest.selectedIFrameVariant.map {
            variant in
            guard let entryIFrameVariant,
                let iFrameTrack = tracks.first(where: {
                    $0.kind == .iFrames
                }),
                let iFrameURL = trackURLs[
                    iFrameTrack.relativePlaylistPath
                ]
            else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            if manifest.schemaVersion
                == HLSOfflinePackageManifest.currentSchemaVersion
            {
                guard variant.matches(entryIFrameVariant) else {
                    throw HLSDownloadError.invalidOfflinePackage
                }
            }
            return try variant.localVariant(
                at: iFrameURL,
                entryVariant: entryIFrameVariant
            )
        }
        return HLSOfflinePackageReceipt(
            directoryURL: directoryURL,
            entryPlaylistURL: entryPlaylistURL,
            tracks: tracks,
            byteCount: scan.byteCount,
            selectedVariant: selectedVariant,
            selectedIFrameVariant: selectedIFrameVariant,
            resumedResourceTransferCount:
                manifest.resumedResourceTransferCount
        )
    }

    private static func parsePlaylist(
        at url: URL
    ) throws -> HLSPlaylist {
        let data = try boundedRegularFileData(
            at: url,
            maximumBytes: maximumPlaylistBytes
        )
        guard let contents = String(data: data, encoding: .utf8) else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        do {
            return try PlaylistResolver().resolve(
                contents,
                relativeTo: url
            )
        } catch {
            throw HLSDownloadError.invalidOfflinePackage
        }
    }

    private static func boundedRegularFileData(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        do {
            let values = try url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ]
            )
            guard values.isRegularFile == true,
                values.isSymbolicLink != true,
                let size = values.fileSize,
                size >= 0,
                size <= maximumBytes
            else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as HLSDownloadError {
            throw error
        } catch {
            throw HLSDownloadError.invalidOfflinePackage
        }
    }

    private static func validateEntryRenditions(
        _ playlist: HLSPlaylist,
        tracks: [HLSOfflinePackageTrack],
        trackURLs: [String: URL],
        strictMetadata: Bool
    ) throws {
        let expected = tracks.filter {
            $0.kind != .primary && $0.kind != .iFrames
        }
        guard playlist.renditions.count == expected.count,
            let entryVariant = playlist.variants.first
        else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        for track in expected {
            guard let expectedKind = track.kind.renditionKind,
                let expectedGroupID = track.kind.referencedGroupID(
                    regularVariant: entryVariant,
                    iFrameVariant: playlist.iFrameVariants.first
                ),
                let trackURL = trackURLs[track.relativePlaylistPath],
                let rendition = playlist.renditions.first(where: {
                    $0.kind == expectedKind
                        && $0.groupID == expectedGroupID
                        && $0.url.map { sameFile($0, trackURL) } == true
                })
            else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            if strictMetadata,
                !track.matches(rendition)
            {
                throw HLSDownloadError.invalidOfflinePackage
            }
        }
    }

    private static func validateEntryIFrameVariant(
        _ playlist: HLSPlaylist,
        tracks: [HLSOfflinePackageTrack],
        trackURLs: [String: URL]
    ) throws -> HLSVariant? {
        let tracks = tracks.filter { $0.kind == .iFrames }
        guard playlist.iFrameVariants.count == tracks.count else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        guard let track = tracks.first else {
            return nil
        }
        guard let trackURL = trackURLs[track.relativePlaylistPath],
            let variant = playlist.iFrameVariants.first,
            sameFile(variant.url, trackURL)
        else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        return variant
    }

    private static func isValidFileRecord(
        _ record: HLSOfflinePackageManifest.FileRecord
    ) -> Bool {
        record.byteCount >= 0
            && record.sha256.utf8.count == 64
            && record.sha256.allSatisfy {
                "0123456789abcdef".contains($0)
            }
    }

    private static func recordOrder(
        _ lhs: HLSOfflinePackageManifest.FileRecord,
        _ rhs: HLSOfflinePackageManifest.FileRecord
    ) -> Bool {
        Array(lhs.path.utf8).lexicographicallyPrecedes(
            Array(rhs.path.utf8)
        )
    }

    private static func sameFile(
        _ lhs: URL,
        _ rhs: URL
    ) -> Bool {
        lhs.standardizedFileURL == rhs.standardizedFileURL
    }
}

private extension HLSOfflinePackageManifest.Variant {
    func matches(_ variant: HLSVariant) -> Bool {
        bandwidth == variant.bandwidth
            && averageBandwidth == variant.averageBandwidth
            && score == variant.score
            && width == variant.width
            && height == variant.height
            && codecs == variant.codecs
            && supplementalCodecs == variant.supplementalCodecs
            && frameRate == variant.frameRate
            && videoRange == variant.videoRange
            && hdcpLevel == variant.hdcpLevel?.rawValue
            && allowedContentProtectionConfigurations
                == variant.allowedContentProtectionConfigurations.map(
                    HLSOfflinePackageManifest
                        .AllowedContentProtectionConfiguration.init
                )
            && requiredVideoLayouts
                == variant.requiredVideoLayouts.map(
                    HLSOfflinePackageManifest.RequiredVideoLayout.init
                )
            && stableID == variant.stableID
    }
}

private extension HLSOfflinePackageTrackKind {
    var renditionKind: HLSRenditionKind? {
        switch self {
        case .primary:
            return nil
        case .audio:
            return .audio
        case .subtitles:
            return .subtitles
        case .video, .iFrameVideo:
            return .video
        case .iFrames:
            return nil
        }
    }

    func referencedGroupID(
        regularVariant: HLSVariant,
        iFrameVariant: HLSVariant?
    ) -> String? {
        switch self {
        case .primary, .iFrames:
            return nil
        case .audio:
            return regularVariant.audioGroupID
        case .subtitles:
            return regularVariant.subtitleGroupID
        case .video:
            return regularVariant.videoGroupID
        case .iFrameVideo:
            return iFrameVariant?.videoGroupID
        }
    }
}

private extension HLSOfflinePackageTrack {
    func matches(_ rendition: HLSRendition) -> Bool {
        name == rendition.name
            && language == rendition.language
            && associatedLanguage == rendition.associatedLanguage
            && stableID == rendition.stableID
            && instreamID == rendition.instreamID
            && characteristics == rendition.characteristics
            && channels == rendition.channels
            && audioBitDepth == rendition.audioBitDepth
            && audioSampleRate == rendition.audioSampleRate
            && isDefault == rendition.isDefault
            && isAutoselect == rendition.isAutoselect
            && isForced == rendition.isForced
    }
}
