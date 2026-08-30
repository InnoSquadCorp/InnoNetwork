import Foundation

struct HLSTimelineMetadata: Sendable {
    let preferredStartPosition: HLSPreferredStartPosition?
    let programDateTimes: [HLSProgramDateTime]
    let dateRanges: [HLSDateRange]
    let unsupportedMediaFeatures: [HLSUnsupportedMediaFeature]
}

enum HLSTimelineParser {
    private static let dateRangePrefix = "#EXT-X-DATERANGE:"
    private static let programDateTimePrefix =
        "#EXT-X-PROGRAM-DATE-TIME:"
    private static let startPrefix = "#EXT-X-START:"
    static let interstitialClass = "com.apple.hls.interstitial"
    static let dateRangeScheduleClass =
        "com.apple.hls.daterange-schedule"
    static let dateRangePreloadClass = "com.apple.hls.preload"

    static func parse(
        _ lines: [String],
        kind: HLSPlaylist.Kind,
        relativeTo sourceURL: URL
    ) throws -> HLSTimelineMetadata {
        let start = try parseStartPosition(lines)
        guard kind == .media else {
            guard
                !lines.contains(where: {
                    $0.hasPrefix(dateRangePrefix)
                        || $0.hasPrefix(programDateTimePrefix)
                })
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            return HLSTimelineMetadata(
                preferredStartPosition: start,
                programDateTimes: [],
                dateRanges: [],
                unsupportedMediaFeatures: []
            )
        }

        let programDateTimes = try parseProgramDateTimes(lines)
        let dateRanges = try parseDateRanges(
            lines,
            relativeTo: sourceURL,
            allowsPreloading: !lines.contains("#EXT-X-ENDLIST")
        )
        guard dateRanges.isEmpty || !programDateTimes.isEmpty else {
            throw HLSDownloadError.invalidPlaylist
        }

        var unsupported: [HLSUnsupportedMediaFeature] = []
        if dateRanges.contains(where: { $0.interstitial != nil }) {
            unsupported.append(.interstitialResource)
        }
        if dateRanges.contains(where: { $0.externalResource != nil }) {
            unsupported.append(.dateRangeExternalResource)
        }
        return HLSTimelineMetadata(
            preferredStartPosition: start,
            programDateTimes: programDateTimes,
            dateRanges: dateRanges,
            unsupportedMediaFeatures: unsupported
        )
    }

    private static func parseStartPosition(
        _ lines: [String]
    ) throws -> HLSPreferredStartPosition? {
        let tags = lines.filter { $0.hasPrefix(startPrefix) }
        guard tags.count <= 1 else {
            throw HLSDownloadError.invalidPlaylist
        }
        guard let tag = tags.first else {
            return nil
        }
        let attributes = try HLSAttributeListParser.parse(
            String(tag.dropFirst(startPrefix.count))
        )
        guard
            let offsetValue = attributes["TIME-OFFSET"],
            !attributes.isQuoted("TIME-OFFSET")
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        let offset = try parseFiniteDouble(offsetValue)
        let isPrecise = try parseYesNo(
            attributes["PRECISE"],
            defaultValue: false,
            isQuoted: attributes.isQuoted("PRECISE")
        )
        return HLSPreferredStartPosition(
            timeOffset: offset,
            isPrecise: isPrecise
        )
    }

    private static func parseProgramDateTimes(
        _ lines: [String]
    ) throws -> [HLSProgramDateTime] {
        var result: [HLSProgramDateTime] = []
        var pendingDate: Date?
        var expectsSegmentURI = false
        var segmentIndex = 0

        for line in lines {
            if line.hasPrefix(programDateTimePrefix) {
                guard pendingDate == nil else {
                    throw HLSDownloadError.invalidPlaylist
                }
                pendingDate = try parseDate(
                    String(line.dropFirst(programDateTimePrefix.count))
                )
            } else if line.hasPrefix("#EXTINF:") {
                guard !expectsSegmentURI else {
                    throw HLSDownloadError.invalidPlaylist
                }
                expectsSegmentURI = true
            } else if !line.isEmpty, !line.hasPrefix("#"),
                expectsSegmentURI
            {
                if let pendingDate {
                    result.append(
                        HLSProgramDateTime(
                            segmentIndex: segmentIndex,
                            date: pendingDate
                        )
                    )
                }
                pendingDate = nil
                expectsSegmentURI = false
                segmentIndex += 1
            }
        }
        guard pendingDate == nil else {
            throw HLSDownloadError.invalidPlaylist
        }
        return result
    }

    private static func parseDateRanges(
        _ lines: [String],
        relativeTo sourceURL: URL,
        allowsPreloading: Bool
    ) throws -> [HLSDateRange] {
        var order: [String] = []
        var attributesByID: [String: HLSAttributeList] = [:]

        for line in lines where line.hasPrefix(dateRangePrefix) {
            let attributes = try HLSAttributeListParser.parse(
                String(line.dropFirst(dateRangePrefix.count))
            )
            guard let id = attributes["ID"],
                attributes.isQuoted("ID"),
                !id.isEmpty
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            if let existing = attributesByID[id] {
                attributesByID[id] = try existing.merging(attributes)
            } else {
                guard attributes["START-DATE"] != nil,
                    attributes.isQuoted("START-DATE")
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                order.append(id)
                attributesByID[id] = attributes
            }
        }

        let ranges = try order.map { id -> HLSDateRange in
            guard let attributes = attributesByID[id] else {
                throw HLSDownloadError.invalidPlaylist
            }
            return try makeDateRange(
                id: id,
                attributes: attributes,
                relativeTo: sourceURL,
                allowsPreloading: allowsPreloading
            )
        }
        try validateClassTimelines(ranges)
        return ranges
    }

    static func makeDateRange(
        id: String,
        attributes: HLSAttributeList,
        relativeTo sourceURL: URL,
        allowsPreloading: Bool
    ) throws -> HLSDateRange {
        guard let startValue = attributes["START-DATE"],
            attributes.isQuoted("START-DATE")
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        let startDate = try parseDate(startValue)
        let className = try quotedNonemptyValue(
            "CLASS",
            in: attributes
        )
        let endDate = try quotedNonemptyValue(
            "END-DATE",
            in: attributes
        ).map(parseDate)
        let duration = try parseOptionalNonnegativeDouble(
            "DURATION",
            in: attributes
        )
        let plannedDuration = try parseOptionalNonnegativeDouble(
            "PLANNED-DURATION",
            in: attributes
        )
        if let endDate, endDate < startDate {
            throw HLSDownloadError.invalidPlaylist
        }
        if let endDate, let duration,
            abs(endDate.timeIntervalSince(startDate) - duration) > 0.001
        {
            throw HLSDownloadError.invalidPlaylist
        }

        let cues = try parseCues(attributes)
        let endsOnNext: Bool
        if let value = attributes["END-ON-NEXT"] {
            guard value == "YES", !attributes.isQuoted("END-ON-NEXT"),
                className != nil, endDate == nil, duration == nil
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            endsOnNext = true
        } else {
            endsOnNext = false
        }

        let interstitial = try parseInterstitial(
            attributes,
            className: className,
            relativeTo: sourceURL
        )
        let externalResource = try parseExternalResource(
            attributes,
            relativeTo: sourceURL
        )
        let preload = try parsePreload(
            attributes,
            className: className,
            externalResource: externalResource,
            endDate: endDate,
            duration: duration,
            cues: cues,
            endsOnNext: endsOnNext,
            allowsPreloading: allowsPreloading
        )
        if className == dateRangeScheduleClass,
            externalResource == nil
        {
            throw HLSDownloadError.invalidPlaylist
        }
        let extensionNames = attributes.attributeNames
            .filter {
                $0.hasPrefix("X-")
                    || $0.hasPrefix("SCTE35-")
            }
            .sorted()
        return HLSDateRange(
            id: id,
            className: className,
            startDate: startDate,
            endDate: endDate,
            duration: duration,
            plannedDuration: plannedDuration,
            cues: cues,
            endsOnNext: endsOnNext,
            interstitial: interstitial,
            externalResource: externalResource,
            preload: preload,
            extensionAttributeNames: extensionNames
        )
    }

    private static func parsePreload(
        _ attributes: HLSAttributeList,
        className: String?,
        externalResource: HLSDateRangeResource?,
        endDate: Date?,
        duration: TimeInterval?,
        cues: [HLSDateRangeCue],
        endsOnNext: Bool,
        allowsPreloading: Bool
    ) throws -> HLSDateRangePreload? {
        let durationAtJoin = try parseOptionalFiniteDouble(
            "X-DURATION-AT-JOIN",
            in: attributes
        )
        let hasPreloadOnlyAttributes =
            attributes["X-TARGET-ID"] != nil
            || attributes["X-TARGET-CLASS"] != nil
            || durationAtJoin != nil
        guard className == dateRangePreloadClass else {
            guard !hasPreloadOnlyAttributes else {
                throw HLSDownloadError.invalidPlaylist
            }
            return nil
        }
        guard
            let externalResource,
            let targetID = externalResource.targetID,
            let targetClass = externalResource.targetClass,
            endDate != nil || duration != nil,
            cues.isEmpty,
            !endsOnNext,
            durationAtJoin != 0
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return HLSDateRangePreload(
            resource: externalResource,
            targetID: targetID,
            targetClass: targetClass,
            durationAtJoin: durationAtJoin,
            isEligible: allowsPreloading
        )
    }

    private static func parseCues(
        _ attributes: HLSAttributeList
    ) throws -> [HLSDateRangeCue] {
        guard let value = attributes["CUE"] else {
            return []
        }
        guard attributes.isQuoted("CUE") else {
            throw HLSDownloadError.invalidPlaylist
        }
        let tokens = value.split(
            separator: ",",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !tokens.isEmpty, tokens.allSatisfy({ !$0.isEmpty }),
            Set(tokens).count == tokens.count
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        let cues = try tokens.map { token -> HLSDateRangeCue in
            switch token {
            case "PRE":
                return .pre
            case "POST":
                return .post
            case "ONCE":
                return .once
            default:
                throw HLSDownloadError.invalidPlaylist
            }
        }
        guard !(cues.contains(.pre) && cues.contains(.post)) else {
            throw HLSDownloadError.invalidPlaylist
        }
        return cues
    }

    private static func parseInterstitial(
        _ attributes: HLSAttributeList,
        className: String?,
        relativeTo sourceURL: URL
    ) throws -> HLSInterstitial? {
        let assetValue = attributes["X-ASSET-URI"]
        let assetListValue = attributes["X-ASSET-LIST"]
        guard className == interstitialClass else {
            guard assetValue == nil, assetListValue == nil else {
                throw HLSDownloadError.invalidPlaylist
            }
            return nil
        }
        guard (assetValue == nil) != (assetListValue == nil) else {
            throw HLSDownloadError.invalidPlaylist
        }

        let source: HLSInterstitialSource
        if let assetValue {
            guard attributes.isQuoted("X-ASSET-URI"),
                let url = URL(string: assetValue),
                url.scheme != nil
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            source = .asset(url)
        } else if let assetListValue {
            guard attributes.isQuoted("X-ASSET-LIST"),
                let url = URL(
                    string: assetListValue,
                    relativeTo: sourceURL
                )?.absoluteURL
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            source = .assetList(url)
        } else {
            throw HLSDownloadError.invalidPlaylist
        }
        let resumeOffset = try parseOptionalFiniteDouble(
            "X-RESUME-OFFSET",
            in: attributes
        )
        let playoutLimit = try parseOptionalNonnegativeDouble(
            "X-PLAYOUT-LIMIT",
            in: attributes
        )
        return HLSInterstitial(
            source: source,
            resumeOffset: resumeOffset,
            playoutLimit: playoutLimit
        )
    }

    private static func parseExternalResource(
        _ attributes: HLSAttributeList,
        relativeTo sourceURL: URL
    ) throws -> HLSDateRangeResource? {
        guard let uri = attributes["X-URI"] else {
            return nil
        }
        guard attributes.isQuoted("X-URI"),
            let url = URL(
                string: uri,
                relativeTo: sourceURL
            )?.absoluteURL
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        let targetID = try quotedNonemptyValue(
            "X-TARGET-ID",
            in: attributes
        )
        let targetClass = try quotedNonemptyValue(
            "X-TARGET-CLASS",
            in: attributes
        )
        return HLSDateRangeResource(
            url: url,
            targetID: targetID,
            targetClass: targetClass
        )
    }

    static func validateClassTimelines(
        _ ranges: [HLSDateRange]
    ) throws {
        let classesWithEndsOnNext = Set(
            ranges.compactMap {
                $0.endsOnNext ? $0.className : nil
            }
        )
        for className in classesWithEndsOnNext {
            let classRanges =
                ranges
                .filter { $0.className == className }
                .sorted { $0.startDate < $1.startDate }
            for index in classRanges.indices.dropLast() {
                let range = classRanges[index]
                let next = classRanges[classRanges.index(after: index)]
                let endDate =
                    range.endDate
                    ?? range.duration.map {
                        range.startDate.addingTimeInterval($0)
                    }
                    ?? (range.endsOnNext ? next.startDate : nil)
                if let endDate, endDate > next.startDate {
                    throw HLSDownloadError.invalidPlaylist
                }
            }
        }
    }

    private static func quotedNonemptyValue(
        _ name: String,
        in attributes: HLSAttributeList
    ) throws -> String? {
        guard let value = attributes[name] else {
            return nil
        }
        guard attributes.isQuoted(name), !value.isEmpty else {
            throw HLSDownloadError.invalidPlaylist
        }
        return value
    }

    private static func parseOptionalFiniteDouble(
        _ name: String,
        in attributes: HLSAttributeList
    ) throws -> Double? {
        guard let value = attributes[name],
            !attributes.isQuoted(name)
        else {
            if attributes[name] != nil {
                throw HLSDownloadError.invalidPlaylist
            }
            return nil
        }
        return try parseFiniteDouble(value)
    }

    private static func parseOptionalNonnegativeDouble(
        _ name: String,
        in attributes: HLSAttributeList
    ) throws -> Double? {
        guard
            let value = try parseOptionalFiniteDouble(
                name,
                in: attributes
            )
        else {
            return nil
        }
        guard value >= 0 else {
            throw HLSDownloadError.invalidPlaylist
        }
        return value
    }

    private static func parseFiniteDouble(
        _ value: String
    ) throws -> Double {
        guard !value.isEmpty,
            value.contains(where: { $0.isASCII && $0.isNumber }),
            value.enumerated().allSatisfy({
                $0.element.isASCII
                    && ($0.element.isNumber
                        || $0.element == "."
                        || ($0.offset == 0 && $0.element == "-"))
            }),
            value.count(where: { $0 == "." }) <= 1,
            let parsed = Double(value),
            parsed.isFinite
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return parsed
    }

    private static func parseYesNo(
        _ value: String?,
        defaultValue: Bool,
        isQuoted: Bool
    ) throws -> Bool {
        guard let value else {
            return defaultValue
        }
        guard !isQuoted else {
            throw HLSDownloadError.invalidPlaylist
        }
        switch value {
        case "YES":
            return true
        case "NO":
            return false
        default:
            throw HLSDownloadError.invalidPlaylist
        }
    }

    static func parseDate(
        _ value: String
    ) throws -> Date {
        let normalized = hasTimeZone(value) ? value : value + "Z"
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = fractional.date(from: normalized) {
            return date
        }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        guard let date = wholeSeconds.date(from: normalized) else {
            throw HLSDownloadError.invalidPlaylist
        }
        return date
    }

    private static func hasTimeZone(_ value: String) -> Bool {
        guard let timeSeparator = value.firstIndex(of: "T") else {
            return false
        }
        let time = value[timeSeparator...]
        return time.hasSuffix("Z")
            || time.dropFirst().contains("+")
            || time.dropFirst().contains("-")
    }
}
