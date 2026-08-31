import Foundation

enum HLSInterstitialParser {
    static func parse(
        _ attributes: HLSAttributeList,
        className: String?,
        relativeTo sourceURL: URL
    ) throws -> HLSInterstitial? {
        let assetValue = attributes["X-ASSET-URI"]
        let assetListValue = attributes["X-ASSET-LIST"]
        guard className == HLSTimelineParser.interstitialClass else {
            guard assetValue == nil, assetListValue == nil else {
                throw HLSDownloadError.invalidPlaylist
            }
            return nil
        }
        guard (assetValue == nil) != (assetListValue == nil) else {
            throw HLSDownloadError.invalidPlaylist
        }

        return HLSInterstitial(
            source: try source(
                assetValue: assetValue,
                assetListValue: assetListValue,
                attributes: attributes,
                relativeTo: sourceURL
            ),
            resumeOffset: try optionalFiniteDouble(
                "X-RESUME-OFFSET",
                in: attributes
            ),
            playoutLimit: try optionalNonnegativeDouble(
                "X-PLAYOUT-LIMIT",
                in: attributes
            ),
            timelineOccupancy: try timelineOccupancy(attributes),
            timelineStyle: try timelineStyle(attributes),
            navigationRestrictions: try navigationRestrictions(attributes),
            skipControl: try skipControl(attributes)
        )
    }

    private static func source(
        assetValue: String?,
        assetListValue: String?,
        attributes: HLSAttributeList,
        relativeTo sourceURL: URL
    ) throws -> HLSInterstitialSource {
        if let assetValue {
            guard attributes.isQuoted("X-ASSET-URI"),
                let url = URL(string: assetValue),
                url.scheme != nil
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            return .asset(url)
        }
        guard let assetListValue,
            attributes.isQuoted("X-ASSET-LIST"),
            let url = URL(
                string: assetListValue,
                relativeTo: sourceURL
            )?.absoluteURL
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return .assetList(url)
    }

    private static func timelineOccupancy(
        _ attributes: HLSAttributeList
    ) throws -> HLSInterstitialTimelineOccupancy {
        guard let value = attributes["X-TIMELINE-OCCUPIES"] else {
            return .point
        }
        guard attributes.isQuoted("X-TIMELINE-OCCUPIES") else {
            throw HLSDownloadError.invalidPlaylist
        }
        switch value {
        case "POINT":
            return .point
        case "RANGE":
            return .range
        default:
            return .point
        }
    }

    private static func timelineStyle(
        _ attributes: HLSAttributeList
    ) throws -> HLSInterstitialTimelineStyle {
        guard let value = attributes["X-TIMELINE-STYLE"] else {
            return .highlight
        }
        guard attributes.isQuoted("X-TIMELINE-STYLE") else {
            throw HLSDownloadError.invalidPlaylist
        }
        switch value {
        case "HIGHLIGHT":
            return .highlight
        case "PRIMARY":
            return .primary
        default:
            return .highlight
        }
    }

    private static func navigationRestrictions(
        _ attributes: HLSAttributeList
    ) throws -> Set<HLSInterstitialNavigationRestriction> {
        guard let value = attributes["X-RESTRICT"] else {
            return []
        }
        guard attributes.isQuoted("X-RESTRICT") else {
            throw HLSDownloadError.invalidPlaylist
        }
        let tokens = value.split(
            separator: ",",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !tokens.isEmpty,
            tokens.allSatisfy({ token in
                !token.isEmpty
                    && token.allSatisfy {
                        $0.isASCII
                            && ($0.isUppercase
                                || $0.isNumber
                                || $0 == "-")
                    }
            })
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return Set(
            tokens.compactMap { token in
                switch token {
                case "SKIP":
                    return HLSInterstitialNavigationRestriction.skip
                case "JUMP":
                    return HLSInterstitialNavigationRestriction.jump
                default:
                    return nil
                }
            }
        )
    }

    private static func skipControl(
        _ attributes: HLSAttributeList
    ) throws -> HLSInterstitialSkipControl? {
        let offset = try optionalWholeSeconds(
            "X-SKIP-CONTROL-OFFSET",
            in: attributes
        )
        let duration = try optionalWholeSeconds(
            "X-SKIP-CONTROL-DURATION",
            in: attributes
        )
        let labelID = try optionalSkipLabelID(attributes)
        guard offset != nil || duration != nil || labelID != nil else {
            return nil
        }
        return HLSInterstitialSkipControl(
            offset: offset,
            duration: duration,
            labelID: labelID
        )
    }

    private static func optionalSkipLabelID(
        _ attributes: HLSAttributeList
    ) throws -> String? {
        let name = "X-SKIP-CONTROL-LABEL-ID"
        guard let value = attributes[name] else {
            return nil
        }
        guard attributes.isQuoted(name),
            value.allSatisfy({
                $0.isASCII
                    && ($0.isLetter || $0 == "-" || $0 == "_")
            })
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return value
    }

    private static func optionalWholeSeconds(
        _ name: String,
        in attributes: HLSAttributeList
    ) throws -> UInt64? {
        guard let value = attributes[name] else {
            return nil
        }
        guard !attributes.isQuoted(name),
            !value.isEmpty,
            value.allSatisfy({ $0.isASCII && $0.isNumber }),
            let parsed = UInt64(value)
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return parsed
    }

    private static func optionalFiniteDouble(
        _ name: String,
        in attributes: HLSAttributeList
    ) throws -> Double? {
        guard let value = attributes[name] else {
            return nil
        }
        guard !attributes.isQuoted(name) else {
            throw HLSDownloadError.invalidPlaylist
        }
        return try finiteDouble(value)
    }

    private static func optionalNonnegativeDouble(
        _ name: String,
        in attributes: HLSAttributeList
    ) throws -> Double? {
        guard let value = try optionalFiniteDouble(name, in: attributes) else {
            return nil
        }
        guard value >= 0 else {
            throw HLSDownloadError.invalidPlaylist
        }
        return value
    }

    private static func finiteDouble(_ value: String) throws -> Double {
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
}
