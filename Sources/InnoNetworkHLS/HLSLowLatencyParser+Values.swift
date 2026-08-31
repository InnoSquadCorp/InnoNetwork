import Foundation

extension HLSLowLatencyParser {
    static func yesNo(
        _ attributes: HLSAttributeList,
        name: String
    ) throws -> Bool {
        guard let value = attributes[name] else {
            return false
        }
        guard !attributes.isQuoted(name) else {
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

    static func optionalPositiveDecimal(
        _ attributes: HLSAttributeList,
        name: String
    ) throws -> Double? {
        guard let value = attributes[name] else {
            return nil
        }
        guard !attributes.isQuoted(name) else {
            throw HLSDownloadError.invalidPlaylist
        }
        return try positiveDecimal(value)
    }

    static func positiveDecimal(
        _ value: String
    ) throws -> Double {
        guard let result = Double(value), result.isFinite, result > 0 else {
            throw HLSDownloadError.invalidPlaylist
        }
        return result
    }

    static func optionalNonnegativeInteger(
        _ attributes: HLSAttributeList,
        name: String
    ) throws -> Int64? {
        guard let value = attributes[name] else {
            return nil
        }
        guard
            !attributes.isQuoted(name),
            let result = Int64(value),
            result >= 0
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return result
    }

    static func optionalPositiveInteger(
        _ attributes: HLSAttributeList,
        name: String
    ) throws -> Int64? {
        guard
            let result = try optionalNonnegativeInteger(
                attributes,
                name: name
            )
        else {
            return nil
        }
        guard result > 0 else {
            throw HLSDownloadError.invalidPlaylist
        }
        return result
    }

    static func optionalNonnegativeInt(
        _ attributes: HLSAttributeList,
        name: String
    ) throws -> Int? {
        guard
            let result = try optionalNonnegativeInteger(
                attributes,
                name: name
            ),
            result <= Int64(Int.max)
        else {
            if attributes[name] == nil {
                return nil
            }
            throw HLSDownloadError.invalidPlaylist
        }
        return Int(result)
    }

    static func resolveByteRange(
        _ value: String,
        previous: HLSByteRange?
    ) throws -> HLSByteRange {
        let fields = value.split(
            separator: "@",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard
            let lengthValue = fields.first,
            let length = Int64(lengthValue),
            length > 0
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        let offset: Int64
        if fields.count == 2 {
            guard let explicitOffset = Int64(fields[1]),
                explicitOffset >= 0
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            offset = explicitOffset
        } else {
            guard let previous else {
                throw HLSDownloadError.invalidPlaylist
            }
            offset = previous.endOffset
        }
        guard let range = HLSByteRange(offset: offset, length: length) else {
            throw HLSDownloadError.invalidPlaylist
        }
        return range
    }
}
