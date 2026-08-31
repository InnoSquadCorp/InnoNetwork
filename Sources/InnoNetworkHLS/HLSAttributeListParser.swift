import Foundation

struct HLSAttributeList {
    private let values: [String: String]
    private let quotedNames: Set<String>

    init(
        values: [String: String],
        quotedNames: Set<String>
    ) {
        self.values = values
        self.quotedNames = quotedNames
    }

    subscript(_ name: String) -> String? {
        values[name]
    }

    func isQuoted(_ name: String) -> Bool {
        quotedNames.contains(name)
    }

    var attributeNames: Set<String> {
        Set(values.keys)
    }

    var semanticFingerprint: String {
        HLSContentFingerprint.sha256(
            attributeNames.sorted().map { name in
                [
                    name,
                    isQuoted(name) ? "quoted" : "unquoted",
                    values[name] ?? "",
                ].joined(separator: "\u{1f}")
            }.joined(separator: "\u{1e}")
        )
    }

    func merging(
        _ other: HLSAttributeList
    ) throws -> HLSAttributeList {
        var mergedValues = values
        var mergedQuotedNames = quotedNames
        for name in other.attributeNames {
            guard let value = other[name] else {
                continue
            }
            if let existing = mergedValues[name] {
                guard existing == value,
                    quotedNames.contains(name) == other.isQuoted(name)
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
            } else {
                mergedValues[name] = value
                if other.isQuoted(name) {
                    mergedQuotedNames.insert(name)
                }
            }
        }
        return HLSAttributeList(
            values: mergedValues,
            quotedNames: mergedQuotedNames
        )
    }
}

enum HLSAttributeListParser {
    static func parse(_ text: String) throws -> HLSAttributeList {
        var fields: [String] = []
        var current = ""
        var isQuoted = false

        for character in text {
            if character == "\"" {
                isQuoted.toggle()
                current.append(character)
            } else if character == ",", !isQuoted {
                fields.append(current)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
            }
        }
        guard !isQuoted else {
            throw HLSDownloadError.invalidPlaylist
        }
        fields.append(current)

        var attributes: [String: String] = [:]
        var quotedNames: Set<String> = []
        for field in fields {
            let pair = field.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard pair.count == 2 else {
                throw HLSDownloadError.invalidPlaylist
            }
            let key = pair[0].trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let rawValue = pair[1].trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard
                !key.isEmpty,
                key.allSatisfy({
                    $0.isASCII
                        && ($0.isUppercase || $0.isNumber || $0 == "-")
                }),
                !rawValue.isEmpty,
                attributes[key] == nil
            else {
                throw HLSDownloadError.invalidPlaylist
            }

            let value: String
            if rawValue.first == "\"" {
                guard rawValue.count >= 2, rawValue.last == "\"" else {
                    throw HLSDownloadError.invalidPlaylist
                }
                let interior = rawValue.dropFirst().dropLast()
                guard
                    !interior.contains("\""),
                    !interior.contains("\r"),
                    !interior.contains("\n")
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                value = String(interior)
                quotedNames.insert(key)
            } else {
                guard !rawValue.contains("\"") else {
                    throw HLSDownloadError.invalidPlaylist
                }
                value = rawValue
            }
            attributes[key] = value
        }
        return HLSAttributeList(
            values: attributes,
            quotedNames: quotedNames
        )
    }
}

enum HLSDateRangeFingerprintParser {
    private static let prefix = "#EXT-X-DATERANGE:"

    static func parse(_ contents: String) -> [String: String] {
        var attributesByID: [String: HLSAttributeList] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix(prefix),
                let attributes = try? HLSAttributeListParser.parse(
                    String(line.dropFirst(prefix.count))
                ),
                let id = attributes["ID"]
            else {
                continue
            }
            if let existing = attributesByID[id] {
                guard let merged = try? existing.merging(attributes) else {
                    continue
                }
                attributesByID[id] = merged
            } else {
                attributesByID[id] = attributes
            }
        }
        return attributesByID.mapValues(\.semanticFingerprint)
    }
}
