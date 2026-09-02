import Foundation

enum HLSPlaylistDiagnosticAnalyzer {
    private static let attributeTagPrefixes = [
        "#EXT-X-CONTENT-STEERING:",
        "#EXT-X-DATERANGE:",
        "#EXT-X-DEFINE:",
        "#EXT-X-I-FRAME-STREAM-INF:",
        "#EXT-X-KEY:",
        "#EXT-X-MAP:",
        "#EXT-X-MEDIA:",
        "#EXT-X-PART:",
        "#EXT-X-PART-INF:",
        "#EXT-X-PRELOAD-HINT:",
        "#EXT-X-RENDITION-REPORT:",
        "#EXT-X-SERVER-CONTROL:",
        "#EXT-X-SESSION-DATA:",
        "#EXT-X-SESSION-KEY:",
        "#EXT-X-SKIP:",
        "#EXT-X-START:",
        "#EXT-X-STREAM-INF:",
    ]
    private static let singletonTags = [
        "#EXT-X-CONTENT-STEERING:",
        "#EXT-X-DISCONTINUITY-SEQUENCE:",
        "#EXT-X-ENDLIST",
        "#EXT-X-INDEPENDENT-SEGMENTS",
        "#EXT-X-MEDIA-SEQUENCE:",
        "#EXT-X-PART-INF:",
        "#EXT-X-PLAYLIST-TYPE:",
        "#EXT-X-SERVER-CONTROL:",
        "#EXT-X-SKIP:",
        "#EXT-X-START:",
        "#EXT-X-TARGETDURATION:",
        "#EXT-X-VERSION:",
    ]

    static func inspect(
        _ source: String,
        relativeTo sourceURL: URL,
        resolver: PlaylistResolver,
        pack: HLSPlaylistInspectionPack
    ) -> HLSPlaylistInspection {
        do {
            try resolver.validateRawPlaylistSize(source)
        } catch {
            return HLSPlaylistInspection(
                playlist: nil,
                diagnostics: [
                    HLSPlaylistDiagnostic(
                        severity: .error,
                        scope: .playlist,
                        code: .playlistTooLarge,
                        lineNumber: nil
                    )
                ]
            )
        }
        let lines = numberedLines(in: source)
        var diagnostics = syntaxDiagnostics(in: lines)
        do {
            let playlist = try resolver.resolve(
                source,
                relativeTo: sourceURL
            )
            diagnostics.append(
                contentsOf: capabilityDiagnostics(
                    for: playlist,
                    lines: lines
                )
            )
            if pack.includesAppleAuthoringGuidance {
                diagnostics.append(
                    contentsOf: HLSAppleAuthoringAnalyzer.diagnostics(
                        for: playlist,
                        lines: lines.map {
                            HLSAuthoringLine(
                                number: $0.number,
                                text: $0.text
                            )
                        }
                    )
                )
            }
            return HLSPlaylistInspection(
                playlist: playlist,
                diagnostics: ordered(diagnostics)
            )
        } catch let error as HLSDownloadError {
            if error.code == .playlistTooLarge,
                !diagnostics.contains(where: {
                    $0.code == .playlistTooLarge
                })
            {
                diagnostics.append(
                    HLSPlaylistDiagnostic(
                        severity: .error,
                        scope: .playlist,
                        code: .playlistTooLarge,
                        lineNumber: nil
                    )
                )
            } else if !diagnostics.contains(where: {
                $0.scope == .playlist && $0.severity == .error
            }) {
                diagnostics.append(
                    HLSPlaylistDiagnostic(
                        severity: .error,
                        scope: .playlist,
                        code: .invalidPlaylist,
                        lineNumber: nil
                    )
                )
            }
            return HLSPlaylistInspection(
                playlist: nil,
                diagnostics: ordered(diagnostics)
            )
        } catch {
            if !diagnostics.contains(where: {
                $0.scope == .playlist && $0.severity == .error
            }) {
                diagnostics.append(
                    HLSPlaylistDiagnostic(
                        severity: .error,
                        scope: .playlist,
                        code: .invalidPlaylist,
                        lineNumber: nil
                    )
                )
            }
            return HLSPlaylistInspection(
                playlist: nil,
                diagnostics: ordered(diagnostics)
            )
        }
    }

    private static func syntaxDiagnostics(
        in lines: [NumberedLine]
    ) -> [HLSPlaylistDiagnostic] {
        var diagnostics: [HLSPlaylistDiagnostic] = []
        guard let first = lines.first(where: { !$0.text.isEmpty }) else {
            return [
                syntaxError(.missingHeader, lineNumber: nil)
            ]
        }
        if first.text != "#EXTM3U" {
            diagnostics.append(
                syntaxError(.missingHeader, lineNumber: first.number)
            )
        }
        for prefix in singletonTags {
            let matches = lines.filter {
                prefix.hasSuffix(":")
                    ? $0.text.hasPrefix(prefix)
                    : $0.text == prefix
            }
            diagnostics.append(
                contentsOf: matches.dropFirst().map {
                    syntaxError(.duplicateTag, lineNumber: $0.number)
                }
            )
        }
        for line in lines {
            guard
                let prefix = attributeTagPrefixes.first(where: {
                    line.text.hasPrefix($0)
                })
            else {
                continue
            }
            let attributes: HLSAttributeList
            do {
                attributes = try HLSAttributeListParser.parse(
                    String(line.text.dropFirst(prefix.count))
                )
            } catch {
                diagnostics.append(
                    syntaxError(
                        .malformedAttributeList,
                        lineNumber: line.number
                    )
                )
                continue
            }
            let requiredNames: [String]
            switch prefix {
            case "#EXT-X-STREAM-INF:":
                requiredNames = ["BANDWIDTH"]
            case "#EXT-X-I-FRAME-STREAM-INF:":
                requiredNames = ["BANDWIDTH", "URI"]
            case "#EXT-X-MEDIA:":
                requiredNames = ["TYPE", "GROUP-ID", "NAME"]
            case "#EXT-X-MAP:":
                requiredNames = ["URI"]
            case "#EXT-X-KEY:":
                requiredNames = ["METHOD"]
            case "#EXT-X-CONTENT-STEERING:":
                requiredNames = ["SERVER-URI"]
            case "#EXT-X-DATERANGE:":
                requiredNames = ["ID"]
            case "#EXT-X-START:":
                requiredNames = ["TIME-OFFSET"]
            case "#EXT-X-PART-INF:":
                requiredNames = ["PART-TARGET"]
            case "#EXT-X-PART:":
                requiredNames = ["URI", "DURATION"]
            case "#EXT-X-PRELOAD-HINT:":
                requiredNames = ["TYPE", "URI"]
            case "#EXT-X-RENDITION-REPORT:":
                requiredNames = ["URI"]
            case "#EXT-X-SKIP:":
                requiredNames = ["SKIPPED-SEGMENTS"]
            case "#EXT-X-SESSION-DATA:":
                requiredNames = ["DATA-ID"]
            case "#EXT-X-SESSION-KEY:":
                requiredNames = ["METHOD", "URI"]
            default:
                requiredNames = []
            }
            if requiredNames.contains(where: {
                attributes[$0] == nil
            }) {
                diagnostics.append(
                    syntaxError(
                        .missingRequiredAttribute,
                        lineNumber: line.number
                    )
                )
            }
        }

        let multivariantLines = lines.filter {
            $0.text.hasPrefix("#EXT-X-STREAM-INF:")
                || $0.text.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:")
        }
        let mediaLine = lines.first(where: isMediaSegmentDeclaration)
        if !multivariantLines.isEmpty, let mediaLine {
            diagnostics.append(
                syntaxError(
                    .mixedPlaylistKinds,
                    lineNumber: mediaLine.number
                )
            )
        }
        for line in multivariantLines
        where line.text.hasPrefix("#EXT-X-STREAM-INF:") {
            guard
                let next = lines.dropFirst(line.number).first(where: {
                    !$0.text.isEmpty
                }),
                !next.text.hasPrefix("#")
            else {
                diagnostics.append(
                    syntaxError(
                        .missingVariantURI,
                        lineNumber: line.number
                    )
                )
                continue
            }
        }
        return diagnostics
    }

    private static func ordered(
        _ diagnostics: [HLSPlaylistDiagnostic]
    ) -> [HLSPlaylistDiagnostic] {
        diagnostics.enumerated().sorted { lhs, rhs in
            let lhsLine = lhs.element.lineNumber ?? .max
            let rhsLine = rhs.element.lineNumber ?? .max
            if lhsLine != rhsLine {
                return lhsLine < rhsLine
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func capabilityDiagnostics(
        for playlist: HLSPlaylist,
        lines: [NumberedLine]
    ) -> [HLSPlaylistDiagnostic] {
        switch playlist.kind {
        case .media:
            return mediaDiagnostics(for: playlist, lines: lines)
        case .multivariant:
            return multivariantDiagnostics(for: playlist, lines: lines)
        }
    }

    private static func mediaDiagnostics(
        for playlist: HLSPlaylist,
        lines: [NumberedLine]
    ) -> [HLSPlaylistDiagnostic] {
        guard let media = playlist.media else {
            return []
        }
        var diagnostics: [HLSPlaylistDiagnostic] = []
        if media.segmentCount == 0 {
            diagnostics.append(
                contentsOf: operationErrors(
                    code: .emptyMediaPlaylist,
                    lineNumber: nil
                )
            )
        }
        if !media.hasEndList {
            diagnostics.append(
                contentsOf: operationErrors(
                    code: .livePlaylistUnsupported,
                    lineNumber: nil
                )
            )
        }
        for feature in media.unsupportedFeatures {
            let lineNumber = lineNumber(for: feature, in: lines)
            if feature == .preloadHintResource
                || feature == .renditionReportResource
            {
                diagnostics.append(
                    HLSPlaylistDiagnostic(
                        severity: .error,
                        scope: .offlinePackage,
                        code: .mediaFeatureUnsupported,
                        lineNumber: lineNumber,
                        mediaFeature: feature
                    )
                )
            } else {
                diagnostics.append(
                    contentsOf: operationErrors(
                        code: .mediaFeatureUnsupported,
                        lineNumber: lineNumber,
                        mediaFeature: feature
                    )
                )
            }
        }
        if media.unsupportedEncryptionMethodForTransfer != nil {
            diagnostics.append(
                contentsOf: operationErrors(
                    code: .encryptionUnsupported,
                    lineNumber: lines.first(where: {
                        $0.text.hasPrefix("#EXT-X-KEY:")
                    })?.number
                )
            )
        }
        return diagnostics
    }

    private static func multivariantDiagnostics(
        for playlist: HLSPlaylist,
        lines: [NumberedLine]
    ) -> [HLSPlaylistDiagnostic] {
        var diagnostics: [HLSPlaylistDiagnostic] = []
        let unsupportedVariantIndex = playlist.variants.firstIndex {
            guard let groupID = $0.audioGroupID else {
                return false
            }
            return playlist.separateAudioGroupIDs.contains(groupID)
        }
        if let unsupportedVariantIndex {
            let hasSupportedVariant = playlist.variants.contains {
                guard let groupID = $0.audioGroupID else {
                    return true
                }
                return !playlist.separateAudioGroupIDs.contains(groupID)
            }
            diagnostics.append(
                HLSPlaylistDiagnostic(
                    severity: hasSupportedVariant ? .warning : .error,
                    scope: .singleFileDownload,
                    code: .separateAudioRendition,
                    lineNumber: nthLineNumber(
                        prefix: "#EXT-X-STREAM-INF:",
                        index: unsupportedVariantIndex,
                        in: lines
                    )
                )
            )
        }
        if playlist.contentSteering != nil {
            let missingVariantIndex = playlist.variants.firstIndex {
                $0.stableID == nil
            }
            if let missingVariantIndex {
                diagnostics.append(
                    HLSPlaylistDiagnostic(
                        severity: .error,
                        scope: .offlinePackage,
                        code: .missingStableVariantID,
                        lineNumber: nthLineNumber(
                            prefix: "#EXT-X-STREAM-INF:",
                            index: missingVariantIndex,
                            in: lines
                        )
                    )
                )
            }
            let regularGroupKeys = renditionGroupKeys(
                in: playlist.variants
            )
            let iFrameGroupKeys = renditionGroupKeys(
                in: playlist.iFrameVariants
            )
            let missingRenditionIndex = playlist.renditions.firstIndex {
                $0.url != nil && $0.stableID == nil
                    && regularGroupKeys.contains(
                        RenditionGroupKey(
                            kind: $0.kind,
                            groupID: $0.groupID
                        )
                    )
            }
            if let missingRenditionIndex {
                diagnostics.append(
                    HLSPlaylistDiagnostic(
                        severity: .error,
                        scope: .offlinePackage,
                        code: .missingStableRenditionID,
                        lineNumber: nthLineNumber(
                            prefix: "#EXT-X-MEDIA:",
                            index: missingRenditionIndex,
                            in: lines
                        )
                    )
                )
            }
            let missingIFrameRenditionIndex =
                playlist.renditions.firstIndex {
                    let key = RenditionGroupKey(
                        kind: $0.kind,
                        groupID: $0.groupID
                    )
                    return $0.url != nil && $0.stableID == nil
                        && iFrameGroupKeys.contains(key)
                        && !regularGroupKeys.contains(key)
                }
            if let missingIFrameRenditionIndex {
                diagnostics.append(
                    HLSPlaylistDiagnostic(
                        severity: .warning,
                        scope: .offlinePackage,
                        code: .missingStableRenditionID,
                        lineNumber: nthLineNumber(
                            prefix: "#EXT-X-MEDIA:",
                            index: missingIFrameRenditionIndex,
                            in: lines
                        )
                    )
                )
            }
            if let missingIFrameIndex = playlist.iFrameVariants.firstIndex(
                where: { $0.stableID == nil }
            ) {
                diagnostics.append(
                    HLSPlaylistDiagnostic(
                        severity: .warning,
                        scope: .offlinePackage,
                        code: .missingStableVariantID,
                        lineNumber: nthLineNumber(
                            prefix: "#EXT-X-I-FRAME-STREAM-INF:",
                            index: missingIFrameIndex,
                            in: lines
                        )
                    )
                )
            }
        }
        for (index, variant) in playlist.iFrameVariants.enumerated() {
            guard let width = variant.width, let height = variant.height,
                !playlist.variants.contains(where: {
                    $0.width == width && $0.height == height
                })
            else {
                continue
            }
            diagnostics.append(
                HLSPlaylistDiagnostic(
                    severity: .warning,
                    scope: .offlinePackage,
                    code: .iFrameResolutionMismatch,
                    lineNumber: nthLineNumber(
                        prefix: "#EXT-X-I-FRAME-STREAM-INF:",
                        index: index,
                        in: lines
                    )
                )
            )
        }
        return diagnostics
    }

    private static func renditionGroupKeys(
        in variants: [HLSVariant]
    ) -> Set<RenditionGroupKey> {
        var keys: Set<RenditionGroupKey> = []
        for variant in variants {
            if let groupID = variant.audioGroupID {
                keys.insert(.init(kind: .audio, groupID: groupID))
            }
            if let groupID = variant.subtitleGroupID {
                keys.insert(.init(kind: .subtitles, groupID: groupID))
            }
            if let groupID = variant.videoGroupID {
                keys.insert(.init(kind: .video, groupID: groupID))
            }
            if case .group(let groupID) = variant.closedCaptions {
                keys.insert(
                    .init(kind: .closedCaptions, groupID: groupID)
                )
            }
        }
        return keys
    }

    private static func operationErrors(
        code: HLSPlaylistDiagnostic.Code,
        lineNumber: Int?,
        mediaFeature: HLSUnsupportedMediaFeature? = nil
    ) -> [HLSPlaylistDiagnostic] {
        [
            HLSPlaylistDiagnostic(
                severity: .error,
                scope: .singleFileDownload,
                code: code,
                lineNumber: lineNumber,
                mediaFeature: mediaFeature
            ),
            HLSPlaylistDiagnostic(
                severity: .error,
                scope: .offlinePackage,
                code: code,
                lineNumber: lineNumber,
                mediaFeature: mediaFeature
            ),
        ]
    }

    private static func lineNumber(
        for feature: HLSUnsupportedMediaFeature,
        in lines: [NumberedLine]
    ) -> Int? {
        switch feature {
        case .discontinuity:
            return lines.first(where: {
                $0.text == "#EXT-X-DISCONTINUITY"
            })?.number
        case .gap:
            return lines.first(where: { $0.text == "#EXT-X-GAP" })?.number
        case .iFramesOnly:
            return lines.first(where: {
                $0.text == "#EXT-X-I-FRAMES-ONLY"
            })?.number
        case .multipleInitializationSections:
            return lines.filter {
                $0.text.hasPrefix("#EXT-X-MAP:")
            }.dropFirst().first?.number
        case .interstitialResource:
            return lines.first(where: {
                $0.text.hasPrefix("#EXT-X-DATERANGE:")
                    && ($0.text.contains("X-ASSET-URI=")
                        || $0.text.contains("X-ASSET-LIST="))
            })?.number
        case .dateRangeExternalResource:
            return lines.first(where: {
                $0.text.hasPrefix("#EXT-X-DATERANGE:")
                    && $0.text.contains("X-URI=")
            })?.number
        case .partialSegments:
            return lines.first(where: {
                $0.text.hasPrefix("#EXT-X-PART:")
            })?.number
        case .preloadHintResource:
            return lines.first(where: {
                $0.text.hasPrefix("#EXT-X-PRELOAD-HINT:")
            })?.number
        case .renditionReportResource:
            return lines.first(where: {
                $0.text.hasPrefix("#EXT-X-RENDITION-REPORT:")
            })?.number
        case .deltaUpdate:
            return lines.first(where: {
                $0.text.hasPrefix("#EXT-X-SKIP:")
            })?.number
        }
    }

    private static func nthLineNumber(
        prefix: String,
        index: Int,
        in lines: [NumberedLine]
    ) -> Int? {
        let matches = lines.filter { $0.text.hasPrefix(prefix) }
        guard matches.indices.contains(index) else {
            return nil
        }
        return matches[index].number
    }

    private static func numberedLines(
        in source: String
    ) -> [NumberedLine] {
        source.components(separatedBy: .newlines).enumerated().map {
            NumberedLine(
                number: $0.offset + 1,
                text: $0.element.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        }
    }

    private static func isMediaSegmentDeclaration(
        _ line: NumberedLine
    ) -> Bool {
        line.text.hasPrefix("#EXTINF:")
            || line.text.hasPrefix("#EXT-X-BYTERANGE:")
            || line.text.hasPrefix("#EXT-X-BITRATE:")
            || line.text.hasPrefix("#EXT-X-DATERANGE:")
            || line.text.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:")
            || line.text.hasPrefix("#EXT-X-KEY:")
            || line.text.hasPrefix("#EXT-X-MAP:")
            || line.text.hasPrefix("#EXT-X-MEDIA-SEQUENCE:")
            || line.text.hasPrefix("#EXT-X-PART:")
            || line.text.hasPrefix("#EXT-X-PART-INF:")
            || line.text.hasPrefix("#EXT-X-PLAYLIST-TYPE:")
            || line.text.hasPrefix("#EXT-X-PRELOAD-HINT:")
            || line.text.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:")
            || line.text.hasPrefix("#EXT-X-RENDITION-REPORT:")
            || line.text.hasPrefix("#EXT-X-SERVER-CONTROL:")
            || line.text.hasPrefix("#EXT-X-SKIP:")
            || line.text.hasPrefix("#EXT-X-TARGETDURATION:")
            || line.text == "#EXT-X-DISCONTINUITY"
            || line.text == "#EXT-X-ENDLIST"
            || line.text == "#EXT-X-GAP"
            || line.text == "#EXT-X-I-FRAMES-ONLY"
    }

    private static func syntaxError(
        _ code: HLSPlaylistDiagnostic.Code,
        lineNumber: Int?
    ) -> HLSPlaylistDiagnostic {
        HLSPlaylistDiagnostic(
            severity: .error,
            scope: .playlist,
            code: code,
            lineNumber: lineNumber
        )
    }

    private struct NumberedLine {
        let number: Int
        let text: String
    }

    private struct RenditionGroupKey: Hashable {
        let kind: HLSRenditionKind
        let groupID: String

        func hash(into hasher: inout Hasher) {
            hasher.combine(kind)
            hasher.combine(groupID)
        }
    }
}
