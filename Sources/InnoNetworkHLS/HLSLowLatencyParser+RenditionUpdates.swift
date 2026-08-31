import Foundation

extension HLSLowLatencyParser {
    static func parseRenditionReports(
        _ lines: [String],
        relativeTo sourceURL: URL
    ) throws -> [HLSRenditionReport] {
        var reports: [HLSRenditionReport] = []
        var urls: Set<URL> = []
        for line in lines
        where line.hasPrefix("#EXT-X-RENDITION-REPORT:") {
            let attributes = try HLSAttributeListParser.parse(
                String(
                    line.dropFirst(
                        "#EXT-X-RENDITION-REPORT:".count
                    )
                )
            )
            guard
                let uri = attributes["URI"],
                attributes.isQuoted("URI"),
                !uri.isEmpty,
                URL(string: uri)?.scheme == nil,
                let url = URL(
                    string: uri,
                    relativeTo: sourceURL
                )?.absoluteURL,
                urls.insert(url).inserted
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            let lastMediaSequenceNumber =
                try optionalNonnegativeInteger(
                    attributes,
                    name: "LAST-MSN"
                )
            let lastPartialSegmentIndex =
                try optionalNonnegativeInt(
                    attributes,
                    name: "LAST-PART"
                )
            reports.append(
                HLSRenditionReport(
                    url: url,
                    lastMediaSequenceNumber:
                        lastMediaSequenceNumber,
                    lastPartialSegmentIndex:
                        lastPartialSegmentIndex
                )
            )
        }
        return reports
    }

    static func parseDeltaUpdate(
        _ lines: [String]
    ) throws -> HLSDeltaUpdate? {
        let declarations = lines.filter {
            $0.hasPrefix("#EXT-X-SKIP:")
        }
        guard declarations.count <= 1 else {
            throw HLSDownloadError.invalidPlaylist
        }
        guard let declaration = declarations.first else {
            return nil
        }
        let attributes = try HLSAttributeListParser.parse(
            String(declaration.dropFirst("#EXT-X-SKIP:".count))
        )
        guard
            let value = attributes["SKIPPED-SEGMENTS"],
            !attributes.isQuoted("SKIPPED-SEGMENTS"),
            let skippedSegmentCount = Int(value),
            skippedSegmentCount >= 0
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        let recentlyRemovedDateRangeIDs: [String]
        if let value = attributes["RECENTLY-REMOVED-DATERANGES"] {
            guard attributes.isQuoted("RECENTLY-REMOVED-DATERANGES") else {
                throw HLSDownloadError.invalidPlaylist
            }
            recentlyRemovedDateRangeIDs =
                value.split(
                    separator: "\t",
                    omittingEmptySubsequences: false
                ).map(String.init)
            guard
                !recentlyRemovedDateRangeIDs.isEmpty,
                recentlyRemovedDateRangeIDs.allSatisfy({
                    !$0.isEmpty
                }),
                Set(recentlyRemovedDateRangeIDs).count
                    == recentlyRemovedDateRangeIDs.count
            else {
                throw HLSDownloadError.invalidPlaylist
            }
        } else {
            recentlyRemovedDateRangeIDs = []
        }
        return HLSDeltaUpdate(
            skippedSegmentCount: skippedSegmentCount,
            recentlyRemovedDateRangeIDs:
                recentlyRemovedDateRangeIDs
        )
    }

}
