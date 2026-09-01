import Foundation

package enum HLSLocalPlaybackPackageValidationError: Error, Sendable {
    case packageUnavailable
    case entryPlaylistUnavailable
    case unsafePackageContents
}

/// A bounded snapshot of every package playlist reachable from one entry.
///
/// Playlist bytes are frozen before a playback listener starts so a later
/// filesystem mutation cannot introduce a remote resource reference through
/// the local bridge. Media bytes remain on disk and are admitted per request.
package struct HLSLocalPlaybackPackageSnapshot: Sendable {
    private static let maximumPlaylistByteCount = 8 * 1_024 * 1_024
    private static let maximumTotalPlaylistByteCount = 32 * 1_024 * 1_024
    private static let maximumPlaylistCount = 256
    private static let maximumAssetListCount = 256
    private static let maximumAssetListByteCount = 2 * 1_024 * 1_024
    private static let maximumAssetsPerList = 1_000
    private static let maximumReferenceUTF8ByteCount = 4_096

    package let directoryURL: URL
    package let entryRelativePath: String
    package let playlistDataByRelativePath: [String: Data]
    package let frozenResourceDataByRelativePath: [String: Data]

    package init(source: HLSLocalPlaybackSource) throws {
        let sourceDirectoryURL = source.packageDirectoryURL
            .standardizedFileURL
        let sourceEntryURL = source.entryPlaylistURL
            .standardizedFileURL
        let directoryValues: URLResourceValues
        do {
            directoryValues = try sourceDirectoryURL.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]
            )
        } catch {
            throw HLSLocalPlaybackPackageValidationError
                .packageUnavailable
        }
        guard directoryValues.isDirectory == true else {
            throw HLSLocalPlaybackPackageValidationError
                .packageUnavailable
        }
        guard directoryValues.isSymbolicLink != true else {
            throw HLSLocalPlaybackPackageValidationError
                .unsafePackageContents
        }

        let sourcePrefix = Self.directoryPrefix(
            sourceDirectoryURL.path
        )
        guard sourceEntryURL.path.hasPrefix(sourcePrefix) else {
            throw HLSLocalPlaybackPackageValidationError
                .unsafePackageContents
        }
        let entryRelativePath = String(
            sourceEntryURL.path.dropFirst(sourcePrefix.count)
        )
        guard Self.hasSafeDecodedRelativePath(entryRelativePath) else {
            throw HLSLocalPlaybackPackageValidationError
                .unsafePackageContents
        }
        let directoryURL =
            sourceDirectoryURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let entryURL =
            directoryURL
            .appendingPathComponent(entryRelativePath)
            .standardizedFileURL
        let entryValues: URLResourceValues
        do {
            entryValues = try entryURL.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
        } catch {
            throw HLSLocalPlaybackPackageValidationError
                .entryPlaylistUnavailable
        }
        guard entryValues.isSymbolicLink != true else {
            throw HLSLocalPlaybackPackageValidationError
                .unsafePackageContents
        }
        guard entryValues.isRegularFile == true else {
            throw HLSLocalPlaybackPackageValidationError
                .entryPlaylistUnavailable
        }
        let resolvedEntryURL =
            entryURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard entryURL.path == resolvedEntryURL.path,
            Self.contains(resolvedEntryURL, in: directoryURL)
        else {
            throw HLSLocalPlaybackPackageValidationError
                .unsafePackageContents
        }

        var pending = [entryURL]
        var visited: Set<String> = []
        var visitedAssetLists: Set<String> = []
        var playlistDataByRelativePath: [String: Data] = [:]
        var frozenResourceDataByRelativePath: [String: Data] = [:]
        var totalByteCount = 0

        while let playlistURL = pending.popLast() {
            let relativePath = try Self.relativePath(
                of: playlistURL,
                in: directoryURL
            )
            guard visited.insert(relativePath).inserted else {
                continue
            }
            guard visited.count <= Self.maximumPlaylistCount else {
                throw HLSLocalPlaybackPackageValidationError
                    .unsafePackageContents
            }
            let data = try Self.playlistData(
                at: playlistURL,
                in: directoryURL
            )
            let (nextTotal, overflow) =
                totalByteCount
                .addingReportingOverflow(data.count)
            guard !overflow,
                nextTotal <= Self.maximumTotalPlaylistByteCount,
                let contents = String(data: data, encoding: .utf8),
                !contents.contains("{$")
            else {
                throw HLSLocalPlaybackPackageValidationError
                    .unsafePackageContents
            }
            totalByteCount = nextTotal

            let playlist: HLSPlaylist
            do {
                playlist = try PlaylistResolver().resolve(
                    contents,
                    relativeTo: playlistURL
                )
            } catch {
                throw HLSLocalPlaybackPackageValidationError
                    .unsafePackageContents
            }
            let references = try Self.references(
                in: contents,
                kind: playlist.kind
            )
            for reference in references {
                let referencedURL = try Self.localURL(
                    reference.value,
                    relativeTo: playlistURL,
                    in: directoryURL
                )
                if reference.isAssetList {
                    let assetListRelativePath = try Self.relativePath(
                        of: referencedURL,
                        in: directoryURL
                    )
                    if visitedAssetLists.insert(
                        assetListRelativePath
                    ).inserted {
                        guard
                            visitedAssetLists.count
                                <= Self.maximumAssetListCount
                        else {
                            throw HLSLocalPlaybackPackageValidationError
                                .unsafePackageContents
                        }
                        let assetListData = try Self.regularFileData(
                            at: referencedURL,
                            in: directoryURL,
                            maximumByteCount:
                                Self.maximumAssetListByteCount
                        )
                        let (nextTotal, assetListOverflow) =
                            totalByteCount.addingReportingOverflow(
                                assetListData.count
                            )
                        guard !assetListOverflow,
                            nextTotal
                                <= Self.maximumTotalPlaylistByteCount
                        else {
                            throw HLSLocalPlaybackPackageValidationError
                                .unsafePackageContents
                        }
                        totalByteCount = nextTotal
                        let assetReferences: [String]
                        do {
                            assetReferences =
                                try HLSInterstitialAssetListDecoder
                                .decodeLocalAssetReferences(
                                    assetListData,
                                    maximumAssetCount:
                                        Self.maximumAssetsPerList
                                )
                        } catch {
                            throw HLSLocalPlaybackPackageValidationError
                                .unsafePackageContents
                        }
                        for assetReference in assetReferences {
                            let assetURL = try Self.localURL(
                                assetReference,
                                relativeTo: referencedURL,
                                in: directoryURL
                            )
                            guard
                                Self.isContainedRegularFile(
                                    assetURL,
                                    in: directoryURL
                                )
                            else {
                                throw HLSLocalPlaybackPackageValidationError
                                    .unsafePackageContents
                            }
                            pending.append(assetURL)
                        }
                        frozenResourceDataByRelativePath[
                            assetListRelativePath
                        ] = assetListData
                    }
                } else if reference.isPlaylist
                    || referencedURL.pathExtension.lowercased() == "m3u8"
                {
                    guard
                        Self.isContainedRegularFile(
                            referencedURL,
                            in: directoryURL
                        )
                    else {
                        throw HLSLocalPlaybackPackageValidationError
                            .unsafePackageContents
                    }
                    pending.append(referencedURL)
                }
            }
            playlistDataByRelativePath[relativePath] = data
            frozenResourceDataByRelativePath[relativePath] = data
        }

        self.directoryURL = directoryURL
        self.entryRelativePath = entryRelativePath
        self.playlistDataByRelativePath = playlistDataByRelativePath
        self.frozenResourceDataByRelativePath =
            frozenResourceDataByRelativePath
    }

    private struct Reference {
        let value: String
        let isPlaylist: Bool
        let isAssetList: Bool
    }

    private static func references(
        in contents: String,
        kind: HLSPlaylist.Kind
    ) throws -> [Reference] {
        var references: [Reference] = []
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !line.isEmpty else {
                continue
            }
            if !line.hasPrefix("#") {
                references.append(
                    Reference(
                        value: line,
                        isPlaylist: kind == .multivariant,
                        isAssetList: false
                    )
                )
                continue
            }
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let tag = String(line[..<separator])
            let names = Self.uriAttributeNamesByTag[tag] ?? []
            guard !names.isEmpty else {
                continue
            }
            let attributes: HLSAttributeList
            do {
                attributes = try HLSAttributeListParser.parse(
                    String(line[line.index(after: separator)...])
                )
            } catch {
                throw HLSLocalPlaybackPackageValidationError
                    .unsafePackageContents
            }
            if Self.disallowedIndirectAttributesByTag[tag]?.contains(
                where: { attributes[$0] != nil }
            ) == true {
                throw HLSLocalPlaybackPackageValidationError
                    .unsafePackageContents
            }
            for name in names {
                guard let value = attributes[name] else {
                    continue
                }
                references.append(
                    Reference(
                        value: value,
                        isPlaylist:
                            Self.playlistReferenceTags.contains(tag)
                            || (tag == "#EXT-X-DATERANGE"
                                && name == "X-ASSET-URI"),
                        isAssetList:
                            tag == "#EXT-X-DATERANGE"
                            && name == "X-ASSET-LIST"
                    )
                )
            }
        }
        return references
    }

    private static func localURL(
        _ reference: String,
        relativeTo playlistURL: URL,
        in directoryURL: URL
    ) throws -> URL {
        guard !reference.isEmpty,
            reference.utf8.count <= maximumReferenceUTF8ByteCount,
            !reference.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }),
            let components = URLComponents(string: reference),
            components.scheme == nil,
            components.host == nil,
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.query == nil,
            components.fragment == nil,
            hasSafePathComponents(components.percentEncodedPath),
            let url = URL(
                string: reference,
                relativeTo: playlistURL
            )?.absoluteURL.standardizedFileURL,
            url.isFileURL,
            contains(url, in: directoryURL)
        else {
            throw HLSLocalPlaybackPackageValidationError
                .unsafePackageContents
        }
        return url
    }

    private static func hasSafePathComponents(
        _ percentEncodedPath: String
    ) -> Bool {
        let components = percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        guard !components.isEmpty else {
            return false
        }
        return components.allSatisfy { encoded in
            guard let decoded = String(encoded).removingPercentEncoding else {
                return false
            }
            return !decoded.isEmpty
                && decoded != "."
                && decoded != ".."
                && !decoded.contains("/")
                && !decoded.contains("\\")
                && !decoded.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
        }
    }

    private static func hasSafeDecodedRelativePath(
        _ path: String
    ) -> Bool {
        guard !path.isEmpty,
            path.utf8.count <= maximumReferenceUTF8ByteCount
        else {
            return false
        }
        return path.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).allSatisfy { component in
            !component.isEmpty
                && component != "."
                && component != ".."
                && !component.contains("\\")
                && !component.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
        }
    }

    private static func playlistData(
        at url: URL,
        in directoryURL: URL
    ) throws -> Data {
        try regularFileData(
            at: url,
            in: directoryURL,
            maximumByteCount: maximumPlaylistByteCount
        )
    }

    private static func regularFileData(
        at url: URL,
        in directoryURL: URL,
        maximumByteCount: Int
    ) throws -> Data {
        guard isContainedRegularFile(url, in: directoryURL) else {
            throw HLSLocalPlaybackPackageValidationError
                .unsafePackageContents
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.fileSizeKey])
        } catch {
            throw HLSLocalPlaybackPackageValidationError
                .unsafePackageContents
        }
        guard let fileSize = values.fileSize,
            fileSize >= 0,
            fileSize <= maximumByteCount
        else {
            throw HLSLocalPlaybackPackageValidationError
                .unsafePackageContents
        }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= maximumByteCount else {
                throw HLSLocalPlaybackPackageValidationError
                    .unsafePackageContents
            }
            return data
        } catch let error as HLSLocalPlaybackPackageValidationError {
            throw error
        } catch {
            throw HLSLocalPlaybackPackageValidationError
                .unsafePackageContents
        }
    }

    private static func isContainedRegularFile(
        _ url: URL,
        in directoryURL: URL
    ) -> Bool {
        let standardizedURL = url.standardizedFileURL
        let resolvedURL =
            standardizedURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard standardizedURL.path == resolvedURL.path,
            contains(resolvedURL, in: directoryURL)
        else {
            return false
        }
        guard
            let values = try? standardizedURL.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
        else {
            return false
        }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
    }

    private static func relativePath(
        of url: URL,
        in directoryURL: URL
    ) throws -> String {
        let prefix = directoryPrefix(directoryURL.path)
        guard url.path.hasPrefix(prefix) else {
            throw HLSLocalPlaybackPackageValidationError
                .unsafePackageContents
        }
        let relativePath = String(url.path.dropFirst(prefix.count))
        guard !relativePath.isEmpty,
            relativePath.utf8.count <= maximumReferenceUTF8ByteCount
        else {
            throw HLSLocalPlaybackPackageValidationError
                .unsafePackageContents
        }
        return relativePath
    }

    private static func contains(
        _ url: URL,
        in directoryURL: URL
    ) -> Bool {
        url.path.hasPrefix(directoryPrefix(directoryURL.path))
    }

    private static func directoryPrefix(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    private static let playlistReferenceTags: Set<String> = [
        "#EXT-X-I-FRAME-STREAM-INF",
        "#EXT-X-IMAGE-STREAM-INF",
        "#EXT-X-MEDIA",
        "#EXT-X-RENDITION-REPORT",
    ]

    private static let uriAttributeNamesByTag: [String: [String]] = [
        "#EXT-X-CONTENT-STEERING": ["SERVER-URI"],
        "#EXT-X-DATERANGE": [
            "X-ASSET-LIST",
            "X-ASSET-URI",
            "X-URI",
        ],
        "#EXT-X-I-FRAME-STREAM-INF": ["URI"],
        "#EXT-X-IMAGE-STREAM-INF": ["URI"],
        "#EXT-X-KEY": ["URI"],
        "#EXT-X-MAP": ["URI"],
        "#EXT-X-MEDIA": ["URI"],
        "#EXT-X-PART": ["URI"],
        "#EXT-X-PRELOAD-HINT": ["URI"],
        "#EXT-X-RENDITION-REPORT": ["URI"],
        "#EXT-X-SESSION-DATA": ["URI"],
        "#EXT-X-SESSION-KEY": ["URI"],
    ]

    private static let disallowedIndirectAttributesByTag: [String: [String]] = [
        "#EXT-X-CONTENT-STEERING": ["SERVER-URI"],
        "#EXT-X-DATERANGE": [
            "X-URI"
        ],
    ]
}
