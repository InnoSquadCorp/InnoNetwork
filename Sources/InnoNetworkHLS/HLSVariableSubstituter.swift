import Foundation

struct HLSVariableExpansion: Sendable {
    let contents: String
    let variables: [String: String]
    let containsDefinitions: Bool
    let containsImports: Bool
    let containsQueryParameters: Bool
}

enum HLSVariableSubstituter {
    static func expand(
        _ playlist: String,
        sourceURL: URL,
        multivariantVariables: [String: String]?,
        maximumBytes: Int
    ) throws -> HLSVariableExpansion {
        let lines =
            playlist
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let queryItems =
            URLComponents(
                url: sourceURL,
                resolvingAgainstBaseURL: true
            )?.queryItems ?? []
        var variables: [String: String] = [:]
        var output: [String] = []
        var outputByteCount = 0
        var containsDefinitions = false
        var containsImports = false
        var containsQueryParameters = false

        for line in lines {
            if line.hasPrefix("#EXT-X-DEFINE:") {
                containsDefinitions = true
                let attributes = try HLSAttributeListParser.parse(
                    String(line.dropFirst("#EXT-X-DEFINE:".count))
                )
                let selectors = ["NAME", "IMPORT", "QUERYPARAM"].filter {
                    attributes[$0] != nil
                }
                guard selectors.count == 1 else {
                    throw HLSDownloadError.invalidPlaylist
                }

                let name: String
                let value: String
                switch selectors[0] {
                case "NAME":
                    guard
                        let declaredName = attributes["NAME"],
                        let declaredValue = attributes["VALUE"],
                        attributes.isQuoted("NAME"),
                        attributes.isQuoted("VALUE")
                    else {
                        throw HLSDownloadError.invalidPlaylist
                    }
                    name = declaredName
                    value = declaredValue
                case "IMPORT":
                    guard
                        attributes["VALUE"] == nil,
                        let importedName = attributes["IMPORT"],
                        attributes.isQuoted("IMPORT"),
                        let importedValue = multivariantVariables?[importedName]
                    else {
                        throw HLSDownloadError.invalidPlaylist
                    }
                    name = importedName
                    value = importedValue
                    containsImports = true
                case "QUERYPARAM":
                    guard
                        attributes["VALUE"] == nil,
                        let queryName = attributes["QUERYPARAM"],
                        attributes.isQuoted("QUERYPARAM"),
                        let queryValue = queryItems.first(where: {
                            $0.name == queryName && $0.value != nil
                        })?.value,
                        isValidQuotedString(queryValue)
                    else {
                        throw HLSDownloadError.invalidPlaylist
                    }
                    name = queryName
                    value = queryValue
                    containsQueryParameters = true
                default:
                    throw HLSDownloadError.invalidPlaylist
                }

                guard
                    isValidVariableName(name),
                    variables.updateValue(value, forKey: name) == nil
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                continue
            }

            let expandedLine: String
            if !line.isEmpty, !line.hasPrefix("#") {
                expandedLine = try substituteReferences(
                    in: line,
                    variables: variables
                )
            } else if line.hasPrefix("#EXT-X-"), line.contains(":") {
                expandedLine = try substituteAttributeValues(
                    in: line,
                    variables: variables
                )
            } else {
                expandedLine = line
            }
            let (nextByteCount, overflow) =
                outputByteCount
                .addingReportingOverflow(expandedLine.utf8.count + 1)
            guard !overflow, nextByteCount <= maximumBytes else {
                throw HLSDownloadError.playlistTooLarge(limit: maximumBytes)
            }
            outputByteCount = nextByteCount
            output.append(expandedLine)
        }

        while output.last?.isEmpty == true {
            output.removeLast()
        }
        return HLSVariableExpansion(
            contents: output.joined(separator: "\n") + "\n",
            variables: variables,
            containsDefinitions: containsDefinitions,
            containsImports: containsImports,
            containsQueryParameters: containsQueryParameters
        )
    }

    private static func substituteAttributeValues(
        in line: String,
        variables: [String: String]
    ) throws -> String {
        guard let colon = line.firstIndex(of: ":") else {
            return line
        }
        let prefix = line[...colon]
        let value = line[line.index(after: colon)...]
        var output = String(prefix)
        var index = value.startIndex
        var fieldStart = index
        var isQuoted = false

        while index <= value.endIndex {
            let isAtEnd = index == value.endIndex
            if !isAtEnd, value[index] == "\"" {
                isQuoted.toggle()
            }
            if isAtEnd || (!isQuoted && value[index] == ",") {
                let field = String(value[fieldStart..<index])
                output += try substituteAttributeField(
                    field,
                    variables: variables
                )
                if !isAtEnd {
                    output.append(",")
                    index = value.index(after: index)
                    fieldStart = index
                    continue
                }
                break
            }
            index = value.index(after: index)
        }
        guard !isQuoted else {
            throw HLSDownloadError.invalidPlaylist
        }
        return output
    }

    private static func substituteAttributeField(
        _ field: String,
        variables: [String: String]
    ) throws -> String {
        guard let equals = field.firstIndex(of: "=") else {
            return field
        }
        let name = field[...equals]
        let rawValue = String(field[field.index(after: equals)...])
        let trimmedValue = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let leadingWhitespaceCount = rawValue.prefix {
            $0.isWhitespace
        }.count
        let trailingWhitespaceCount = rawValue.reversed().prefix {
            $0.isWhitespace
        }.count
        let leadingWhitespace = String(
            rawValue.prefix(leadingWhitespaceCount)
        )
        let trailingWhitespace = String(
            rawValue.suffix(trailingWhitespaceCount)
        )

        if trimmedValue.first == "\"", trimmedValue.last == "\"",
            trimmedValue.count >= 2
        {
            let interior = String(trimmedValue.dropFirst().dropLast())
            return String(name)
                + leadingWhitespace
                + "\""
                + (try substituteReferences(
                    in: interior,
                    variables: variables
                ))
                + "\""
                + trailingWhitespace
        }

        if trimmedValue.lowercased().hasPrefix("0x")
            || trimmedValue.contains("{$")
        {
            let expanded = try substituteReferences(
                in: trimmedValue,
                variables: variables
            )
            guard
                expanded.lowercased().hasPrefix("0x"),
                !expanded.dropFirst(2).isEmpty,
                expanded.dropFirst(2).allSatisfy(\.isHexDigit)
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            return String(name)
                + leadingWhitespace
                + expanded
                + trailingWhitespace
        }
        return field
    }

    private static func substituteReferences(
        in value: String,
        variables: [String: String]
    ) throws -> String {
        var output = ""
        output.reserveCapacity(value.count)
        var index = value.startIndex

        while index < value.endIndex {
            guard value[index...].hasPrefix("{$") else {
                output.append(value[index])
                index = value.index(after: index)
                continue
            }
            let nameStart = value.index(index, offsetBy: 2)
            guard
                let closingBrace = value[nameStart...].firstIndex(of: "}")
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            let name = String(value[nameStart..<closingBrace])
            guard
                isValidVariableName(name),
                let replacement = variables[name]
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            output += replacement
            index = value.index(after: closingBrace)
        }
        return output
    }

    private static func isValidVariableName(_ value: String) -> Bool {
        !value.isEmpty
            && value.allSatisfy {
                $0.isASCII
                    && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
            }
    }

    private static func isValidQuotedString(_ value: String) -> Bool {
        !value.contains("\"")
            && !value.contains("\r")
            && !value.contains("\n")
    }
}
