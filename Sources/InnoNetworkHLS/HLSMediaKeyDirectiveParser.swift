import Foundation

struct HLSMediaKeyDeclaration: Sendable {
    let method: String
    let keyURL: URL
    let keyFormat: String
    let keyFormatVersions: [Int]
    let explicitInitializationVector: Data?

    var isAES128Identity: Bool {
        method == "AES-128" && normalizedKeyFormat == "identity"
    }

    var normalizedKeyFormat: String {
        keyFormat.caseInsensitiveCompare("identity") == .orderedSame
            ? "identity"
            : keyFormat
    }
}

enum HLSMediaKeyDirective: Sendable {
    case clear
    case select(HLSMediaKeyDeclaration)
}

enum HLSMediaKeyDirectiveParser {
    static func parse(
        _ line: String,
        relativeTo sourceURL: URL
    ) throws -> HLSMediaKeyDirective {
        guard line.hasPrefix("#EXT-X-KEY:") else {
            throw HLSDownloadError.invalidPlaylist
        }
        let attributes = try HLSAttributeListParser.parse(
            String(line.dropFirst("#EXT-X-KEY:".count))
        )
        try HLSPlaylistAttributeDecoder.requireQuotedAttributes(
            ["KEYFORMAT", "KEYFORMATVERSIONS", "URI"],
            in: attributes
        )
        try HLSPlaylistAttributeDecoder.requireUnquotedAttributes(
            ["IV", "METHOD"],
            in: attributes
        )
        guard
            let method = attributes["METHOD"],
            !method.isEmpty
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        if method == "NONE" {
            guard attributes["URI"] == nil,
                attributes["IV"] == nil,
                attributes["KEYFORMAT"] == nil,
                attributes["KEYFORMATVERSIONS"] == nil
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            return .clear
        }

        let keyFormat = attributes["KEYFORMAT"] ?? "identity"
        guard !keyFormat.isEmpty,
            let uri = attributes["URI"],
            !uri.isEmpty,
            let keyURL = URL(
                string: uri,
                relativeTo: sourceURL
            )?.absoluteURL
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        let keyFormatVersions =
            try HLSKeyAttributeParser.parseKeyFormatVersions(
                attributes["KEYFORMATVERSIONS"]
            )
        let initializationVector = try attributes["IV"].map(
            HLSKeyAttributeParser.parseInitializationVector
        )
        let declaration = HLSMediaKeyDeclaration(
            method: method,
            keyURL: keyURL,
            keyFormat: keyFormat,
            keyFormatVersions: keyFormatVersions,
            explicitInitializationVector: initializationVector
        )
        if declaration.isAES128Identity,
            keyFormatVersions != [1]
        {
            throw HLSDownloadError.invalidPlaylist
        }
        if initializationVector != nil,
            method == "AES-256-GCM"
                || method == "SAMPLE-AES-CTR"
        {
            throw HLSDownloadError.invalidPlaylist
        }
        return .select(declaration)
    }
}
