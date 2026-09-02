import Foundation

struct HLSPresentationGraphNode: Sendable {
    let roles: Set<HLSPresentationPlaylistRole>
    let document: HLSResolvedPlaylistDocument
}

private struct HLSPresentationGraphReference: Sendable {
    let url: URL
    var roles: Set<HLSPresentationPlaylistRole>
}

struct HLSPresentationGraphInspector: Sendable {
    private let resolver: PlaylistResolver
    private let pack: HLSPresentationInspectionPack

    init(
        client: HLSHTTPClient,
        pack: HLSPresentationInspectionPack
    ) {
        resolver = PlaylistResolver(
            client: client,
            maximumPlaylistBytes: pack.limits.maximumPlaylistBytes
        )
        self.pack = pack
    }

    func inspect(
        from sourceURL: URL
    ) async throws -> HLSPresentationGraphInspection {
        let entry = try await resolver.resolveDocument(
            from: sourceURL,
            requestTimeout: pack.limits.requestTimeout,
            disablesCaching: true
        )
        guard
            entry.contents.utf8.count
                <= pack.limits.maximumTotalPlaylistBytes
        else {
            throw
                HLSPresentationInspectionError
                .totalPlaylistBytesExceeded(
                    limit: pack.limits.maximumTotalPlaylistBytes
                )
        }

        let nodes: [HLSPresentationGraphNode]
        switch entry.playlist.kind {
        case .media:
            nodes = [
                HLSPresentationGraphNode(
                    roles: [.entry],
                    document: entry
                )
            ]
        case .multivariant:
            let references = Self.references(
                in: entry.playlist
            )
            guard
                references.count + 1
                    <= pack.limits.maximumPlaylistCount
            else {
                throw
                    HLSPresentationInspectionError
                    .playlistLimitExceeded(
                        limit: pack.limits.maximumPlaylistCount
                    )
            }
            nodes = try await load(
                references,
                variables: entry.variables,
                initialByteCount: entry.contents.utf8.count
            )
        }

        let inspections = nodes.enumerated().map { index, node in
            HLSPresentationPlaylistInspection(
                index: index,
                roles: node.roles,
                playlist: node.document.playlist
            )
        }
        return HLSPresentationGraphInspection(
            revision: pack.revision,
            entryPlaylist: entry.playlist,
            mediaPlaylists: inspections,
            diagnostics: HLSPresentationConformanceAnalyzer.analyze(
                nodes,
                revision: pack.revision
            )
        )
    }

    private func load(
        _ references: [HLSPresentationGraphReference],
        variables: [String: String],
        initialByteCount: Int
    ) async throws -> [HLSPresentationGraphNode] {
        guard !references.isEmpty else {
            return []
        }
        let concurrency = min(
            pack.limits.maximumConcurrentRequests,
            references.count
        )
        return try await withThrowingTaskGroup(
            of: (Int, HLSPresentationGraphNode, Int).self
        ) { group in
            var nextIndex = 0
            var totalByteCount = initialByteCount
            var results = [HLSPresentationGraphNode?](
                repeating: nil,
                count: references.count
            )

            func enqueue(_ index: Int) {
                let reference = references[index]
                group.addTask {
                    let document = try await resolver.resolveDocument(
                        from: reference.url,
                        multivariantVariables: variables,
                        purpose: .mediaPlaylist,
                        requestTimeout: pack.limits.requestTimeout,
                        disablesCaching: true
                    )
                    guard document.playlist.kind == .media else {
                        throw HLSDownloadError.invalidPlaylist
                    }
                    return (
                        index,
                        HLSPresentationGraphNode(
                            roles: reference.roles,
                            document: document
                        ),
                        document.contents.utf8.count
                    )
                }
            }

            while nextIndex < concurrency {
                enqueue(nextIndex)
                nextIndex += 1
            }

            while let (index, node, byteCount) = try await group.next() {
                let (nextTotal, overflow) =
                    totalByteCount.addingReportingOverflow(byteCount)
                guard !overflow,
                    nextTotal
                        <= pack.limits.maximumTotalPlaylistBytes
                else {
                    group.cancelAll()
                    throw
                        HLSPresentationInspectionError
                        .totalPlaylistBytesExceeded(
                            limit:
                                pack.limits.maximumTotalPlaylistBytes
                        )
                }
                totalByteCount = nextTotal
                results[index] = node
                if nextIndex < references.count {
                    enqueue(nextIndex)
                    nextIndex += 1
                }
            }

            return try results.map { node in
                guard let node else {
                    throw HLSDownloadError.invalidPlaylist
                }
                return node
            }
        }
    }

    private static func references(
        in playlist: HLSPlaylist
    ) -> [HLSPresentationGraphReference] {
        var references: [HLSPresentationGraphReference] = []
        var indexByURL: [URL: Int] = [:]

        func append(
            _ url: URL,
            role: HLSPresentationPlaylistRole
        ) {
            if let index = indexByURL[url] {
                references[index].roles.insert(role)
            } else {
                indexByURL[url] = references.count
                references.append(
                    HLSPresentationGraphReference(
                        url: url,
                        roles: [role]
                    )
                )
            }
        }

        for variant in playlist.variants {
            append(variant.url, role: .variant)
        }
        let audioGroupIDs = Set(
            playlist.variants.compactMap(\.audioGroupID)
        )
        let videoGroupIDs = Set(
            playlist.variants.compactMap(\.videoGroupID)
        )
        let subtitleGroupIDs = Set(
            playlist.variants.compactMap(\.subtitleGroupID)
        )
        for rendition in playlist.renditions {
            guard let url = rendition.url else {
                continue
            }
            let role: HLSPresentationPlaylistRole
            switch rendition.kind {
            case .audio:
                guard audioGroupIDs.contains(rendition.groupID) else {
                    continue
                }
                role = .audioRendition
            case .video:
                guard videoGroupIDs.contains(rendition.groupID) else {
                    continue
                }
                role = .videoRendition
            case .subtitles:
                guard subtitleGroupIDs.contains(rendition.groupID) else {
                    continue
                }
                role = .subtitleRendition
            case .closedCaptions:
                continue
            }
            append(url, role: role)
        }
        for variant in playlist.iFrameVariants {
            append(variant.url, role: .iFrameVariant)
        }
        return references
    }
}

extension PlaylistResolver {
    /// Fetches a bounded presentation graph and diagnoses cross-playlist
    /// conformance without loading media segments.
    public func inspectPresentation(
        from sourceURL: URL,
        using pack: HLSPresentationInspectionPack = .safeDefaults()
    ) async throws -> HLSPresentationGraphInspection {
        try await HLSPresentationGraphInspector(
            client: client,
            pack: pack
        ).inspect(from: sourceURL)
    }
}
