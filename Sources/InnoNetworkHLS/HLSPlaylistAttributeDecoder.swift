import Foundation

enum HLSVariantAttributeSupport<Value> {
    case supported(Value)
    case unsupported
}

enum HLSPlaylistAttributeDecoder {
    static func parseProtocolVersion(
        _ lines: [String]
    ) throws -> Int? {
        let values = lines.compactMap { line -> String? in
            guard line.hasPrefix("#EXT-X-VERSION:") else {
                return nil
            }
            return String(line.dropFirst("#EXT-X-VERSION:".count))
        }
        guard values.count <= 1 else {
            throw HLSDownloadError.invalidPlaylist
        }
        guard let value = values.first else {
            return nil
        }
        guard let version = Int(value), version > 0 else {
            throw HLSDownloadError.invalidPlaylist
        }
        return version
    }

    static func parseNonemptyString(
        _ value: String?
    ) throws -> String? {
        guard let value else {
            return nil
        }
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else {
            throw HLSDownloadError.invalidPlaylist
        }
        return normalized
    }

    static func parsePathwayID(
        _ value: String?
    ) throws -> String? {
        guard let value else {
            return nil
        }
        guard HLSPathwayID.isValid(value) else {
            throw HLSDownloadError.invalidPlaylist
        }
        return value
    }

    static func parseContentSteering(
        _ lines: [String],
        variants: [HLSVariant],
        relativeTo sourceURL: URL
    ) throws -> HLSContentSteering? {
        let tags = lines.filter {
            $0.hasPrefix("#EXT-X-CONTENT-STEERING:")
        }
        guard tags.count <= 1 else {
            throw HLSDownloadError.invalidPlaylist
        }
        guard let tag = tags.first else {
            return nil
        }
        let attributes = try HLSAttributeListParser.parse(
            String(tag.dropFirst("#EXT-X-CONTENT-STEERING:".count))
        )
        guard
            let serverURI = attributes["SERVER-URI"],
            attributes.isQuoted("SERVER-URI"),
            !serverURI.isEmpty,
            let serverURL = URL(
                string: serverURI,
                relativeTo: sourceURL
            )?.absoluteURL
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        let initialPathwayID = try parsePathwayID(
            attributes["PATHWAY-ID"]
        )
        if attributes["PATHWAY-ID"] != nil,
            !attributes.isQuoted("PATHWAY-ID")
        {
            throw HLSDownloadError.invalidPlaylist
        }
        if let initialPathwayID,
            !variants.contains(where: {
                ($0.pathwayID ?? HLSPathwayID.implicit)
                    == initialPathwayID
            })
        {
            throw HLSDownloadError.invalidPlaylist
        }
        return HLSContentSteering(
            serverURL: serverURL,
            initialPathwayID: initialPathwayID
        )
    }

    static func parseStringList(
        _ value: String?
    ) throws -> [String] {
        guard let value else {
            return []
        }
        let values =
            value
            .split(
                separator: ",",
                omittingEmptySubsequences: false
            )
            .map {
                $0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
        guard
            !values.isEmpty,
            values.allSatisfy({ !$0.isEmpty })
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return values
    }

    static func parsePositiveDouble(
        _ value: String?
    ) throws -> Double? {
        guard let value else {
            return nil
        }
        guard
            value.contains(where: { $0.isASCII && $0.isNumber }),
            value.allSatisfy({
                $0.isASCII && ($0.isNumber || $0 == ".")
            }),
            let parsed = Double(value),
            parsed.isFinite,
            parsed > 0
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return parsed
    }

    static func parsePositiveInteger(
        _ value: String?
    ) throws -> Int? {
        guard let value else {
            return nil
        }
        guard let parsed = Int(value), parsed > 0 else {
            throw HLSDownloadError.invalidPlaylist
        }
        return parsed
    }

    static func parseHDCPLevel(
        _ value: String?
    ) throws -> HLSHDCPLevel? {
        guard let value else {
            return nil
        }
        guard let level = HLSHDCPLevel(rawValue: value) else {
            throw HLSDownloadError.invalidPlaylist
        }
        return level
    }

    static func parseAllowedContentProtectionConfigurations(
        _ value: String?
    ) throws -> [HLSAllowedContentProtectionConfiguration] {
        guard let value else {
            return []
        }
        let entries = value.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        guard !entries.isEmpty else {
            throw HLSDownloadError.invalidPlaylist
        }
        return try entries.map { entry in
            let normalized = entry.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard let separator = normalized.lastIndex(of: ":") else {
                throw HLSDownloadError.invalidPlaylist
            }
            let keyFormat = String(normalized[..<separator])
            let rawLabels = normalized[normalized.index(after: separator)...]
            let labels = rawLabels.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            guard
                !keyFormat.isEmpty,
                !keyFormat.contains("\""),
                !keyFormat.contains("\r"),
                !keyFormat.contains("\n"),
                !labels.isEmpty,
                labels.allSatisfy({ label in
                    !label.isEmpty
                        && label.allSatisfy({
                            $0.isASCII
                                && ($0.isUppercase
                                    || $0.isNumber
                                    || $0 == "-")
                        })
                })
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            return HLSAllowedContentProtectionConfiguration(
                keyFormat: keyFormat,
                labels: labels.map(String.init)
            )
        }
    }

    static func parseVideoRange(
        _ value: String?
    ) throws -> HLSVariantAttributeSupport<String?> {
        guard let value else {
            return .supported(nil)
        }
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).uppercased()
        guard !normalized.isEmpty else {
            throw HLSDownloadError.invalidPlaylist
        }
        guard ["SDR", "HLG", "PQ"].contains(normalized) else {
            return .unsupported
        }
        return .supported(normalized)
    }

    static func parseRequiredVideoLayouts(
        _ value: String?
    ) throws
        -> HLSVariantAttributeSupport<[HLSRequiredVideoLayout]>
    {
        guard let value else {
            return .supported([])
        }
        let entries = value.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        guard !entries.isEmpty else {
            throw HLSDownloadError.invalidPlaylist
        }
        var layouts: [HLSRequiredVideoLayout] = []
        for entry in entries {
            let specifiers = entry.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            guard
                !specifiers.isEmpty,
                specifiers.allSatisfy({ !$0.isEmpty })
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            var channelLayout: HLSVideoChannelLayout?
            var projection: HLSVideoProjection?
            for specifier in specifiers {
                let value = String(specifier)
                if let parsed = HLSVideoChannelLayout(rawValue: value) {
                    guard channelLayout == nil else {
                        throw HLSDownloadError.invalidPlaylist
                    }
                    channelLayout = parsed
                } else if let parsed = HLSVideoProjection(
                    rawValue: value
                ) {
                    guard projection == nil else {
                        throw HLSDownloadError.invalidPlaylist
                    }
                    projection = parsed
                } else {
                    return .unsupported
                }
            }
            layouts.append(
                HLSRequiredVideoLayout(
                    channelLayout: channelLayout,
                    projection: projection
                )
            )
        }
        return .supported(layouts)
    }

    static func requireQuotedAttributes(
        _ names: [String],
        in attributes: HLSAttributeList
    ) throws {
        guard
            names.allSatisfy({
                attributes[$0] == nil || attributes.isQuoted($0)
            })
        else {
            throw HLSDownloadError.invalidPlaylist
        }
    }

    static func requireUnquotedAttributes(
        _ names: [String],
        in attributes: HLSAttributeList
    ) throws {
        guard
            names.allSatisfy({
                attributes[$0] == nil || !attributes.isQuoted($0)
            })
        else {
            throw HLSDownloadError.invalidPlaylist
        }
    }

    static func parseStableID(
        _ value: String?
    ) throws -> String? {
        guard let value else {
            return nil
        }
        guard
            !value.isEmpty,
            value.allSatisfy({ character in
                guard character.isASCII else {
                    return false
                }
                return character.isLetter
                    || character.isNumber
                    || character == "+"
                    || character == "/"
                    || character == "="
                    || character == "."
                    || character == "-"
                    || character == "_"
            })
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return value
    }

    static func parseInstreamID(
        _ value: String?,
        kind: HLSRenditionKind
    ) throws -> String? {
        guard let value else {
            guard kind != .closedCaptions else {
                throw HLSDownloadError.invalidPlaylist
            }
            return nil
        }
        guard !value.isEmpty else {
            throw HLSDownloadError.invalidPlaylist
        }
        if kind == .closedCaptions {
            if ["CC1", "CC2", "CC3", "CC4"].contains(value) {
                return value
            }
            guard value.hasPrefix("SERVICE"),
                let service = Int(value.dropFirst("SERVICE".count)),
                (1...63).contains(service)
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            return value
        }
        guard
            value.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".")
            })
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return value
    }

    static func parseAudioChannels(
        _ value: String?,
        kind: HLSRenditionKind
    ) throws -> String? {
        guard let value else {
            return nil
        }
        guard kind == .audio, !value.isEmpty else {
            throw HLSDownloadError.invalidPlaylist
        }
        let parameters = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard let first = parameters.first,
            let channelCount = Int(first),
            channelCount > 0
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        for parameter in parameters.dropFirst() {
            let identifiers = parameter.split(
                separator: ",",
                omittingEmptySubsequences: false
            )
            guard !identifiers.isEmpty,
                identifiers.allSatisfy({ identifier in
                    !identifier.isEmpty
                        && identifier.allSatisfy({
                            $0.isASCII
                                && ($0.isUppercase
                                    || $0.isNumber
                                    || $0 == "-")
                        })
                })
            else {
                throw HLSDownloadError.invalidPlaylist
            }
        }
        return value
    }

    static func parseAudioInteger(
        _ value: String?,
        kind: HLSRenditionKind
    ) throws -> Int? {
        guard let value else {
            return nil
        }
        guard kind == .audio,
            let integer = Int(value),
            integer >= 0
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return integer
    }

    static func parseResolution(
        _ value: String?
    ) -> (width: Int, height: Int)? {
        guard let value else { return nil }
        let components = value.lowercased().split(separator: "x")
        guard components.count == 2,
            let width = Int(components[0]),
            let height = Int(components[1]),
            width > 0,
            height > 0
        else {
            return nil
        }
        return (width, height)
    }

}
