import Foundation

struct HLSSessionMetadata: Sendable {
    let data: [HLSSessionData]
    let keys: [HLSSessionKey]
}

enum HLSSessionMetadataParser {
    static func parse(
        _ lines: [String],
        kind: HLSPlaylist.Kind,
        protocolVersion: Int?,
        relativeTo sourceURL: URL
    ) throws -> HLSSessionMetadata {
        let dataLines = lines.filter {
            $0.hasPrefix("#EXT-X-SESSION-DATA:")
        }
        let keyLines = lines.filter {
            $0.hasPrefix("#EXT-X-SESSION-KEY:")
        }
        guard dataLines.isEmpty && keyLines.isEmpty || kind == .multivariant
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return HLSSessionMetadata(
            data: try parseData(
                dataLines,
                relativeTo: sourceURL
            ),
            keys: try parseKeys(
                keyLines,
                protocolVersion: protocolVersion,
                relativeTo: sourceURL
            )
        )
    }

    private static func parseData(
        _ lines: [String],
        relativeTo sourceURL: URL
    ) throws -> [HLSSessionData] {
        var result: [HLSSessionData] = []
        var identities: Set<SessionDataIdentity> = []
        for line in lines {
            let attributes = try HLSAttributeListParser.parse(
                String(
                    line.dropFirst("#EXT-X-SESSION-DATA:".count)
                )
            )
            guard
                let dataID = attributes["DATA-ID"],
                attributes.isQuoted("DATA-ID"),
                !dataID.isEmpty
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            let language: String?
            if let value = attributes["LANGUAGE"] {
                guard attributes.isQuoted("LANGUAGE"), !value.isEmpty else {
                    throw HLSDownloadError.invalidPlaylist
                }
                language = value
            } else {
                language = nil
            }
            guard
                identities.insert(
                    SessionDataIdentity(
                        dataID: dataID,
                        language: language
                    )
                ).inserted
            else {
                throw HLSDownloadError.invalidPlaylist
            }

            let content: HLSSessionDataContent
            let format = try parseDataFormat(attributes)
            switch (attributes["VALUE"], attributes["URI"]) {
            case (.some(let value), nil):
                guard attributes.isQuoted("VALUE") else {
                    throw HLSDownloadError.invalidPlaylist
                }
                content = .value(value)
            case (nil, .some(let uri)):
                guard
                    attributes.isQuoted("URI"),
                    !uri.isEmpty,
                    let url = URL(
                        string: uri,
                        relativeTo: sourceURL
                    )?.absoluteURL
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                content = .remote(
                    url,
                    format: format ?? .json
                )
            case (.some, .some), (nil, nil):
                throw HLSDownloadError.invalidPlaylist
            }
            result.append(
                HLSSessionData(
                    dataID: dataID,
                    language: language,
                    content: content,
                    extensionAttributeNames:
                        extensionAttributeNames(
                            in: attributes,
                            standardNames: [
                                "DATA-ID",
                                "FORMAT",
                                "LANGUAGE",
                                "URI",
                                "VALUE",
                            ]
                        )
                )
            )
        }
        return result
    }

    private static func parseKeys(
        _ lines: [String],
        protocolVersion: Int?,
        relativeTo sourceURL: URL
    ) throws -> [HLSSessionKey] {
        var result: [HLSSessionKey] = []
        var identities: Set<SessionKeyIdentity> = []
        for line in lines {
            let attributes = try HLSAttributeListParser.parse(
                String(
                    line.dropFirst("#EXT-X-SESSION-KEY:".count)
                )
            )
            guard
                let methodValue = attributes["METHOD"],
                !attributes.isQuoted("METHOD")
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            let method = methodValue
            guard !method.isEmpty, method != "NONE",
                let uri = attributes["URI"],
                attributes.isQuoted("URI"),
                !uri.isEmpty,
                let url = URL(
                    string: uri,
                    relativeTo: sourceURL
                )?.absoluteURL
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            let keyFormat: String
            if let value = attributes["KEYFORMAT"] {
                guard
                    (protocolVersion ?? 1) >= 5,
                    attributes.isQuoted("KEYFORMAT"),
                    !value.isEmpty
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                keyFormat = value
            } else {
                keyFormat = "identity"
            }
            let keyFormatVersions: [Int]
            if let value = attributes["KEYFORMATVERSIONS"] {
                guard
                    (protocolVersion ?? 1) >= 5,
                    attributes.isQuoted("KEYFORMATVERSIONS")
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                keyFormatVersions =
                    try HLSKeyAttributeParser
                    .parseKeyFormatVersions(value)
            } else {
                keyFormatVersions = [1]
            }
            if attributes["IV"] != nil,
                (protocolVersion ?? 1) < 2
                    || attributes.isQuoted("IV")
            {
                throw HLSDownloadError.invalidPlaylist
            }
            let initializationVector = try attributes["IV"].map(
                HLSKeyAttributeParser.parseInitializationVector
            )
            if initializationVector != nil,
                method == "AES-256-GCM"
                    || method == "SAMPLE-AES-CTR"
            {
                throw HLSDownloadError.invalidPlaylist
            }
            let identity = SessionKeyIdentity(
                method: method,
                uri: uri,
                keyFormat: keyFormat,
                keyFormatVersions: keyFormatVersions,
                initializationVector: initializationVector
            )
            guard identities.insert(identity).inserted else {
                throw HLSDownloadError.invalidPlaylist
            }
            result.append(
                HLSSessionKey(
                    method: method,
                    url: url,
                    keyFormat: keyFormat,
                    keyFormatVersions: keyFormatVersions,
                    initializationVector: initializationVector,
                    extensionAttributeNames:
                        extensionAttributeNames(
                            in: attributes,
                            standardNames: [
                                "IV",
                                "KEYFORMAT",
                                "KEYFORMATVERSIONS",
                                "METHOD",
                                "URI",
                            ]
                        )
                )
            )
        }
        return result
    }

    private static func parseDataFormat(
        _ attributes: HLSAttributeList
    ) throws -> HLSSessionDataFormat? {
        guard let value = attributes["FORMAT"] else {
            return nil
        }
        guard !attributes.isQuoted("FORMAT") else {
            throw HLSDownloadError.invalidPlaylist
        }
        switch value {
        case "JSON":
            return .json
        case "RAW":
            return .raw
        default:
            throw HLSDownloadError.invalidPlaylist
        }
    }

    private static func extensionAttributeNames(
        in attributes: HLSAttributeList,
        standardNames: Set<String>
    ) -> Set<String> {
        Set(
            attributes.attributeNames.filter {
                $0.hasPrefix("X-") && !standardNames.contains($0)
            }
        )
    }

    private struct SessionDataIdentity: Hashable {
        let dataID: String
        let language: String?

        func hash(into hasher: inout Hasher) {
            hasher.combine(dataID)
            hasher.combine(language)
        }
    }

    private struct SessionKeyIdentity: Hashable {
        let method: String
        let uri: String
        let keyFormat: String
        let keyFormatVersions: [Int]
        let initializationVector: Data?

        func hash(into hasher: inout Hasher) {
            hasher.combine(method)
            hasher.combine(uri)
            hasher.combine(keyFormat)
            hasher.combine(keyFormatVersions)
            hasher.combine(initializationVector)
        }
    }
}
